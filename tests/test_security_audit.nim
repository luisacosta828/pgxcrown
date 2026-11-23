import std/[os, osproc, strutils, unittest]
import ../src/pgxcrown/ext_meta
import ../src/pgxcrown/security_audit
import ../src/pgxcrown/pgxtool

suite "Pgxcrown Security v2 - Metadata Policy, Symbol Auditor, DT_NEEDED & ELF RPATH/RUNPATH":

  test "ExtensionMeta parses allowDynamicLoader strictly as JSON boolean":
    let tmpDir = getTempDir() / ("pgx_sec_meta_" & $getCurrentProcessId())
    createDir(tmpDir)
    try:
      var meta = initDefaultExtensionMeta("sec_demo")
      check not meta.allowDynamicLoader
      check not applyPgxExtJson(tmpDir, meta)
      check not meta.allowDynamicLoader

      # Present without allowDynamicLoader -> remains false
      writeFile(tmpDir / "pgxext.json", """{"version": "0.1.0"}""")
      meta = initDefaultExtensionMeta("sec_demo")
      check applyPgxExtJson(tmpDir, meta)
      check not meta.allowDynamicLoader

      # Explicit true / false
      writeFile(tmpDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": true}""")
      meta = initDefaultExtensionMeta("sec_demo")
      check applyPgxExtJson(tmpDir, meta)
      check meta.allowDynamicLoader
      check "allowDynamicLoader" notin renderControlFile(meta)

      writeFile(tmpDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": false}""")
      check applyPgxExtJson(tmpDir, meta)
      check not meta.allowDynamicLoader

      # Non-boolean values must raise ValueError
      for badJson in [
        """{"allowDynamicLoader": "true"}""",
        """{"allowDynamicLoader": 1}""",
        """{"allowDynamicLoader": null}""",
        """{"allowDynamicLoader": []}""",
        """{"allowDynamicLoader": {}}"""
      ]:
        writeFile(tmpDir / "pgxext.json", badJson)
        var badMeta = initDefaultExtensionMeta("sec_demo")
        expect ValueError:
          discard applyPgxExtJson(tmpDir, badMeta)
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)

  test "parseUndefinedSymbolsFromNm handles nm -D -u, nm -u, weak symbols, and GLIBC suffixes":
    let nmSample = """
/tmp/libexample.so:

                 w __cxa_finalize@GLIBC_2.2.5
                 U dlopen@GLIBC_2.34
                 U system@@GLIBC_2.2.5
                 v weak_obj_sym@GLIBC_2.17
0000000000001139 T system
0000000000002040 D exported_data
0000000000000000 U posix_spawn@GLIBC_2.15
syscall@@GLIBC_2.2.5
wordexp U - -
                 U load_file
                 U dlopen@GLIBC_2.34
"""
    let parsed = parseUndefinedSymbolsFromNm(nmSample)
    check parsed == @[
      "__cxa_finalize",
      "dlopen",
      "system",
      "weak_obj_sym",
      "posix_spawn",
      "syscall",
      "wordexp",
      "load_file"
    ]
    # Defined symbol 'unlink' with T must not be flagged as undefined
    let definedOnly = "0000000000001100 T unlink\n0000000000001200 D dlopen\n"
    check parseUndefinedSymbolsFromNm(definedOnly).len == 0

  test "evaluateSymbols enforces BlockedOsSymbols and expanded DynamicLoaderSymbols":
    let strictPolicy = SecurityAuditPolicy(allowDynamicLoader: false)
    let optInPolicy = SecurityAuditPolicy(allowDynamicLoader: true)

    # Safe baseline symbols pass
    let safeRes = evaluateSymbols([
      "malloc@GLIBC_2.2.5", "free@GLIBC_2.2.5", "memcpy@GLIBC_2.14",
      "SPI_connect", "errstart", "pg_detoast_datum"
    ], strictPolicy)
    check safeRes.passed
    check safeRes.blockedSymbols.len == 0
    check safeRes.errors.len == 0

    # Every single blocked OS symbol is rejected even when allowDynamicLoader = true
    check BlockedOsSymbols.len == 72
    for sym in BlockedOsSymbols:
      let res = evaluateSymbols([sym & "@@GLIBC_2.2.5"], optInPolicy)
      check not res.passed
      check sym in res.blockedSymbols
      check sym in res.blockedOsSymbols
      check "SECURITY VIOLATION" in res.errorMessage

    # Every dynamic loader symbol (POSIX, PostgreSQL, Windows) is blocked by default
    check DynamicLoaderSymbols.len == 20
    for expectedSym in [
      "dlopen", "dlsym", "dlvsym", "dlmopen", "dlclose", "dlerror",
      "load_external_function", "lookup_external_function", "load_file",
      "internal_load_library", "pg_dlopen", "pg_dlsym", "pg_dlclose", "pg_dlerror",
      "LoadLibraryA", "LoadLibraryW", "LoadLibraryExA", "LoadLibraryExW",
      "GetProcAddress", "FreeLibrary"
    ]:
      check expectedSym in DynamicLoaderSymbols

    for lsym in DynamicLoaderSymbols:
      let suffix = if lsym in ["dlopen", "dlsym", "dlvsym", "dlmopen", "dlclose", "dlerror"]: "@GLIBC_2.34" else: ""
      let blockedRes = evaluateSymbols([lsym & suffix], strictPolicy)
      check not blockedRes.passed
      check lsym in blockedRes.blockedSymbols
      check lsym in blockedRes.blockedLoaderSymbols
      check "SECURITY VIOLATION" in blockedRes.errorMessage
      check "\"allowDynamicLoader\": true" in blockedRes.errorMessage
      check "pgxext.json" in blockedRes.errorMessage

      let allowedRes = evaluateSymbols([lsym & suffix], optInPolicy)
      check allowedRes.passed
      check allowedRes.blockedSymbols.len == 0
      check lsym in allowedRes.allowedLoaderSymbols

    # Mixed load_file + blocked OS call must still fail under optInPolicy
    let mixedRes = evaluateSymbols(["load_file", "posix_spawn@GLIBC_2.15"], optInPolicy)
    check not mixedRes.passed
    check mixedRes.blockedSymbols == @["posix_spawn"]
    check mixedRes.allowedLoaderSymbols == @["load_file"]

  test "parseRunpathsFromReadelf and evaluateRunpaths block ALL RPATH/RUNPATH entries unconditionally":
    let readelfSample = """
Dynamic section at offset 0x2e68 contains 18 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000f (RPATH)              Library rpath: [/usr/lib/postgresql/18/lib:/opt/safe]
 0x000000000000001d (RUNPATH)            Library runpath: [.:../rel:/tmp:/var/tmp:/dev/shm::/usr/local/lib:]
"""
    let entries = parseRunpathsFromReadelf(readelfSample)
    check entries == @[
      "/usr/lib/postgresql/18/lib",
      "/opt/safe",
      ".",
      "../rel",
      "/tmp",
      "/var/tmp",
      "/dev/shm",
      "",
      "/usr/local/lib",
      ""
    ]
    let bad = evaluateRunpaths(entries)
    check "/usr/lib/postgresql/18/lib" in bad
    check "/opt/safe" in bad
    check "/usr/local/lib" in bad
    check "." in bad
    check "../rel" in bad
    check "/tmp" in bad
    check "/var/tmp" in bad
    check "/dev/shm" in bad
    check "<empty>" in bad

    # Even absolute system or pkglibdir paths must be blocked unconditionally
    check evaluateRunpaths(["/usr/lib", "/usr/local/lib", "/usr/lib/postgresql/18/lib"]) == @[
      "/usr/lib", "/usr/local/lib", "/usr/lib/postgresql/18/lib"
    ]
    check evaluateRunpaths(parseRunpathsFromReadelf(" 0x1d (RUNPATH) Library runpath: []")) == @["<empty>"]
    check evaluateRunpaths([":/usr/lib"]) == @["<empty>", "/usr/lib"]
    check evaluateRunpaths(["/usr/lib:"]) == @["/usr/lib", "<empty>"]
    check evaluateRunpaths(newSeq[string]()).len == 0

  test "parseNeededLibrariesFromReadelf and evaluateNeededLibraries enforce minimal runtime allowlist":
    let readelfSample = """
Dynamic section at offset 0x2e68 contains 18 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libpthread.so.0]
 0x0000000000000001 (NEEDED)             Shared library: [librt.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [ld-linux-x86-64.so.2]
 0x0000000000000001 (NEEDED)             Shared library: [ld-linux-aarch64.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [linux-vdso.so.1]
"""
    let minimalLibs = parseNeededLibrariesFromReadelf(readelfSample)
    check minimalLibs == @[
      "libc.so.6", "libm.so.6", "libpthread.so.0", "librt.so.1",
      "libgcc_s.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1", "linux-vdso.so.1"
    ]
    let strictPolicy = SecurityAuditPolicy(allowDynamicLoader: false)
    let optInPolicy = SecurityAuditPolicy(allowDynamicLoader: true)

    check evaluateNeededLibraries(minimalLibs, strictPolicy).len == 0

    # libdl.so.2 blocked by default, permitted only with allowDynamicLoader == true
    check evaluateNeededLibraries(["libc.so.6", "libdl.so.2"], strictPolicy) == @["libdl.so.2"]
    check evaluateNeededLibraries(["libc.so.6", "libdl.so.2"], optInPolicy).len == 0

    # Arbitrary .so/.dll dependencies always blocked even when allowDynamicLoader == true
    let unapproved = parseNeededLibrariesFromReadelf("""
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libpq.so.5]
 0x0000000000000001 (NEEDED)             Shared library: [libcustom.so]
 0x0000000000000001 (NEEDED)             Shared library: [evil.dll]
 0x0000000000000001 (NEEDED)             Shared library: [/tmp/libc.so.6]
""")
    check evaluateNeededLibraries(unapproved, optInPolicy) == @[
      "libpq.so.5", "libcustom.so", "evil.dll", "/tmp/libc.so.6"
    ]

  test "auditBinaryFile end-to-end against compiled ELF shared libraries":
    let missingRes = auditBinaryFile("/nonexistent/path/missing.so", SecurityAuditPolicy())
    check not missingRes.passed

    when defined(linux):
      if findExe("gcc").len > 0 and findExe("nm").len > 0:
        let tmpDir = getTempDir() / ("pgx_sec_elf_" & $getCurrentProcessId())
        createDir(tmpDir)
        try:
          # 1. Clean safe shared library
          writeFile(tmpDir / "safe.c", "int add_one(int x) { return x + 1; }\n")
          let (_, gccSafeCode) = execCmdEx("gcc -shared -fPIC -o " & quoteShell(tmpDir / "libsafe.so") & " " & quoteShell(tmpDir / "safe.c"))
          check gccSafeCode == 0
          let safeAudit = auditBinaryFile(tmpDir / "libsafe.so", SecurityAuditPolicy())
          check safeAudit.passed
          check safeAudit.unsafeRunpaths.len == 0
          check safeAudit.blockedNeededLibraries.len == 0

          if findExe("readelf").len > 0:
            # 2a. Any RPATH/RUNPATH (even pkglibdir!) must be blocked unconditionally
            let pkgRpathSo = tmpDir / "libpkgrpath.so"
            let (_, gccPkgRpCode) = execCmdEx(
              "gcc -shared -fPIC -Wl,-rpath,/usr/lib/postgresql/18/lib -o " &
              quoteShell(pkgRpathSo) & " " & quoteShell(tmpDir / "safe.c")
            )
            check gccPkgRpCode == 0
            check auditElfRunpath(pkgRpathSo) == @["/usr/lib/postgresql/18/lib"]
            let pkgRpAudit = auditBinaryFile(pkgRpathSo, SecurityAuditPolicy(allowDynamicLoader: true))
            check not pkgRpAudit.passed
            check "/usr/lib/postgresql/18/lib" in pkgRpAudit.unsafeRunpaths
            check "SECURITY VIOLATION" in pkgRpAudit.errorMessage

            # 2b. Relative/tmp/empty RUNPATH also rejected
            let rpathSo = tmpDir / "libbadrpath.so"
            let (_, gccRpCode) = execCmdEx(
              "gcc -shared -fPIC -Wl,--enable-new-dtags,-rpath,.:/tmp:/var/tmp::/usr/lib -o " &
              quoteShell(rpathSo) & " " & quoteShell(tmpDir / "safe.c")
            )
            check gccRpCode == 0
            let rpAudit = auditBinaryFile(rpathSo, SecurityAuditPolicy())
            check not rpAudit.passed
            check "." in rpAudit.unsafeRunpaths
            check "/tmp" in rpAudit.unsafeRunpaths
            check "/var/tmp" in rpAudit.unsafeRunpaths
            check "<empty>" in rpAudit.unsafeRunpaths
            check "/usr/lib" in rpAudit.unsafeRunpaths

            # 2c. Unapproved DT_NEEDED shared library rejected even with allowDynamicLoader = true
            writeFile(tmpDir / "dep.c", "int dep_helper(int x) { return x * 2; }\n")
            let depSo = tmpDir / "libcustom_dep.so"
            let (_, gccDepCode) = execCmdEx(
              "gcc -shared -fPIC -Wl,-soname,libcustom_dep.so -o " &
              quoteShell(depSo) & " " & quoteShell(tmpDir / "dep.c")
            )
            check gccDepCode == 0

            writeFile(tmpDir / "uses_dep.c", "extern int dep_helper(int x); int call_dep(int x) { return dep_helper(x); }\n")
            let usesDepSo = tmpDir / "libuses_dep.so"
            let (_, gccUsesDepCode) = execCmdEx(
              "gcc -shared -fPIC -Wl,--no-as-needed -o " &
              quoteShell(usesDepSo) & " " & quoteShell(tmpDir / "uses_dep.c") & " " & quoteShell(depSo)
            )
            check gccUsesDepCode == 0
            let neededViolations = auditElfNeededLibraries(usesDepSo, SecurityAuditPolicy(allowDynamicLoader: true))
            check "libcustom_dep.so" in neededViolations
            let usesDepAudit = auditBinaryFile(usesDepSo, SecurityAuditPolicy(allowDynamicLoader: true))
            check not usesDepAudit.passed
            check "libcustom_dep.so" in usesDepAudit.blockedNeededLibraries
            check "SECURITY VIOLATION" in usesDepAudit.errorMessage

          # 3. Blocked syscall / posix_spawn / dlopen ELF binaries
          writeFile(tmpDir / "bad_calls.c", """
#define _GNU_SOURCE
#include <dlfcn.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/syscall.h>
int trigger_calls(void) {
  pid_t p = 0;
  char *argv[] = {"/bin/true", NULL};
  posix_spawn(&p, "/bin/true", NULL, NULL, argv, NULL);
  syscall(SYS_getpid);
  void *h = dlopen("libc.so.6", RTLD_LAZY);
  if (h) dlclose(h);
  return 0;
}
""")
          let badSo = tmpDir / "libbadcalls.so"
          let (_, gccBadCode) = execCmdEx(
            "gcc -shared -fPIC -o " & quoteShell(badSo) & " " & quoteShell(tmpDir / "bad_calls.c") & " -ldl"
          )
          check gccBadCode == 0
          let badAudit = auditBinaryFile(badSo, SecurityAuditPolicy(allowDynamicLoader: false))
          check not badAudit.passed
          check "posix_spawn" in badAudit.blockedOsSymbols
          check "syscall" in badAudit.blockedOsSymbols
          check "dlopen" in badAudit.blockedLoaderSymbols

          # 4. Pure dlopen ELF library respects pgxext.json policy via auditBinarySymbols
          writeFile(tmpDir / "dl_only.c", """
#include <dlfcn.h>
int check_dl(void) {
  void *h = dlopen("libc.so.6", RTLD_LAZY);
  if (h) { (void)dlsym(h, "strlen"); dlclose(h); }
  return 0;
}
""")
          let dlDir = tmpDir / "dl_proj"
          createDir(dlDir / "src")
          let dlSo = dlDir / "src" / "dl_proj.so"
          let (_, gccDlCode) = execCmdEx(
            "gcc -shared -fPIC -o " & quoteShell(dlSo) & " " & quoteShell(tmpDir / "dl_only.c") & " -ldl"
          )
          check gccDlCode == 0

          # Default absent pgxext.json -> blocked
          check not auditBinarySymbols(dlSo, dlDir)

          # Explicit opt-in -> passes (including libdl.so.2 on older glibc)
          writeFile(dlDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": true}""")
          check auditBinarySymbols(dlSo, dlDir)

          # Malformed non-bool allowDynamicLoader -> rejected
          writeFile(dlDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": "yes"}""")
          check not auditBinarySymbols(dlSo, dlDir)
        finally:
          if dirExists(tmpDir):
            removeDir(tmpDir)

  test "SecurityPipeline composition, mandatory layer protection, and fail-closed invariants":
    var pipe = defaultPgxcrownPipeline()
    check pipe.layers.len == 2
    check pipe.layers[0].id == "symbols" and pipe.layers[0].kind == slkSymbols and pipe.layers[0].mandatory
    check pipe.layers[1].id == "elf_deps" and pipe.layers[1].kind == slkElfDeps and pipe.layers[1].mandatory

    # Mandatory layers cannot be removed
    check not pipe.removeLayer("symbols")
    check not pipe.removeLayer("elf_deps")
    check not pipe.removeLayer("nonexistent_layer")
    check pipe.layers.len == 2

    # Custom slkCustom layer can be added and removed, duplicate/empty IDs rejected
    let customPass = SecurityLayer(
      id: "custom_banner",
      kind: slkCustom,
      mandatory: false,
      check: proc(ctx: AuditContext): LayerReport =
        LayerReport(
          layerId: "custom_banner",
          kind: slkCustom,
          mandatory: false,
          passed: true,
          findings: @[SecurityFinding(
            layerId: "custom_banner",
            code: "CUSTOM_WARN",
            severity: sevWarning,
            message: "custom advisory note"
          )]
        )
    )
    pipe.addLayer(customPass)
    check pipe.layers.len == 3

    expect ValueError:
      pipe.addLayer(customPass)
    expect ValueError:
      pipe.addLayer(SecurityLayer(id: "   ", kind: slkCustom, mandatory: false, check: customPass.check))

    check pipe.removeLayer("custom_banner")
    check pipe.layers.len == 2

    # Empty pipeline or missing mandatory layer fails closed (PIPELINE_MISSING_MANDATORY_LAYER)
    let dummyCtx = AuditContext(soPath: "/tmp/dummy.so", policy: SecurityAuditPolicy())
    let emptyReport = runPipeline(SecurityPipeline(layers: @[]), dummyCtx)
    check not emptyReport.passed
    check emptyReport.layerReports.len == 1
    check emptyReport.layerReports[0].findings[0].code == "PIPELINE_MISSING_MANDATORY_LAYER"
    check "PIPELINE_MISSING_MANDATORY_LAYER" in emptyReport.errorMessage

    let onlySymbols = SecurityPipeline(layers: @[symbolsSecurityLayer()])
    let missingElfRep = runPipeline(onlySymbols, dummyCtx)
    check not missingElfRep.passed
    check "PIPELINE_MISSING_MANDATORY_LAYER" in missingElfRep.errorMessage

    let onlyElf = SecurityPipeline(layers: @[elfDepsSecurityLayer()])
    let missingSymRep = runPipeline(onlyElf, dummyCtx)
    check not missingSymRep.passed
    check "PIPELINE_MISSING_MANDATORY_LAYER" in missingSymRep.errorMessage

    # Exception or nil callback inside a layer fails closed (LAYER_EXECUTION_ERROR)
    when defined(linux):
      if findExe("gcc").len > 0 and findExe("nm").len > 0 and findExe("readelf").len > 0:
        let tmpDir = getTempDir() / ("pgx_sec_pipe_" & $getCurrentProcessId())
        createDir(tmpDir)
        try:
          writeFile(tmpDir / "clean.c", "int clean_fn(int x) { return x + 1; }\n")
          let cleanSo = tmpDir / "libclean.so"
          let (_, gccCode) = execCmdEx("gcc -shared -fPIC -o " & quoteShell(cleanSo) & " " & quoteShell(tmpDir / "clean.c"))
          check gccCode == 0

          var pipeWithWarn = defaultPgxcrownPipeline()
          pipeWithWarn.addLayer(customPass)
          let okRep = runPipeline(pipeWithWarn, AuditContext(soPath: cleanSo, policy: SecurityAuditPolicy()))
          check okRep.passed
          check okRep.layerReports.len == 3
          check okRep.warnings == @["custom advisory note"]

          var pipeWithThrow = defaultPgxcrownPipeline()
          pipeWithThrow.addLayer(SecurityLayer(
            id: "exploding_layer",
            kind: slkCustom,
            mandatory: false,
            check: proc(ctx: AuditContext): LayerReport =
              raise newException(IOError, "simulated I/O failure")
          ))
          let throwRep = runPipeline(pipeWithThrow, AuditContext(soPath: cleanSo, policy: SecurityAuditPolicy()))
          check not throwRep.passed
          check throwRep.layerReports[^1].findings[0].code == "LAYER_EXECUTION_ERROR"
          check "LAYER_EXECUTION_ERROR" in throwRep.errorMessage

          var pipeWithCustomFail = defaultPgxcrownPipeline()
          pipeWithCustomFail.addLayer(SecurityLayer(
            id: "integrity_fail",
            kind: slkIntegrity,
            mandatory: false,
            check: proc(ctx: AuditContext): LayerReport =
              LayerReport(
                layerId: "integrity_fail",
                kind: slkIntegrity,
                mandatory: false,
                passed: false,
                findings: @[SecurityFinding(
                  layerId: "integrity_fail",
                  code: "INTEGRITY_MISMATCH",
                  severity: sevError,
                  message: "manifest digest mismatch"
                )]
              )
          ))
          let failRep = runPipeline(pipeWithCustomFail, AuditContext(soPath: cleanSo, policy: SecurityAuditPolicy()))
          check not failRep.passed
          check "SECURITY VIOLATION" in failRep.errorMessage
          check "manifest digest mismatch" in failRep.errorMessage
        finally:
          if dirExists(tmpDir):
            removeDir(tmpDir)

