import std/[os, osproc, strutils, unittest]
import ../src/pgxcrown/ext_meta
import ../src/pgxcrown/security_audit
import ../src/pgxcrown/pgxtool

suite "Pgxcrown Security v2 - Metadata Policy, Symbol Auditor & ELF RUNPATH":

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
      "wordexp"
    ]
    # Defined symbol 'unlink' with T must not be flagged as undefined
    let definedOnly = "0000000000001100 T unlink\n0000000000001200 D dlopen\n"
    check parseUndefinedSymbolsFromNm(definedOnly).len == 0

  test "evaluateSymbols enforces expanded BlockedOsSymbols and default-deny DynamicLoaderSymbols":
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

    # Every dynamic loader symbol is blocked by default with clear opt-in guidance
    check DynamicLoaderSymbols == ["dlopen", "dlsym", "dlvsym", "dlmopen", "dlclose", "dlerror"]
    for lsym in DynamicLoaderSymbols:
      let blockedRes = evaluateSymbols([lsym & "@GLIBC_2.34"], strictPolicy)
      check not blockedRes.passed
      check lsym in blockedRes.blockedSymbols
      check lsym in blockedRes.blockedLoaderSymbols
      check "SECURITY VIOLATION" in blockedRes.errorMessage
      check "\"allowDynamicLoader\": true" in blockedRes.errorMessage
      check "pgxext.json" in blockedRes.errorMessage

      let allowedRes = evaluateSymbols([lsym & "@GLIBC_2.34"], optInPolicy)
      check allowedRes.passed
      check allowedRes.blockedSymbols.len == 0
      check lsym in allowedRes.allowedLoaderSymbols

    # Mixed dlopen + blocked OS call must still fail under optInPolicy
    let mixedRes = evaluateSymbols(["dlopen@GLIBC_2.34", "posix_spawn@GLIBC_2.15"], optInPolicy)
    check not mixedRes.passed
    check mixedRes.blockedSymbols == @["posix_spawn"]
    check mixedRes.allowedLoaderSymbols == @["dlopen"]

  test "parseRunpathsFromReadelf and evaluateRunpaths detect all unsafe RPATH/RUNPATH forms":
    let readelfSample = """
Dynamic section at offset 0x2e68 contains 18 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000f (RPATH)              Library rpath: [/usr/lib/postgresql/18/lib:/opt/safe]
 0x000000000000001d (RUNPATH)            Library runpath: [.:../rel:/tmp:/tmp/sub:/var/tmp:/dev/shm::/usr/local/lib:]
"""
    let entries = parseRunpathsFromReadelf(readelfSample)
    check entries == @[
      "/usr/lib/postgresql/18/lib",
      "/opt/safe",
      ".",
      "../rel",
      "/tmp",
      "/tmp/sub",
      "/var/tmp",
      "/dev/shm",
      "",
      "/usr/local/lib",
      ""
    ]
    let bad = evaluateRunpaths(entries)
    check "." in bad
    check "../rel" in bad
    check "/tmp" in bad
    check "/tmp/sub" in bad
    check "/var/tmp" in bad
    check "/dev/shm" in bad
    check "<empty>" in bad
    check "/usr/lib/postgresql/18/lib" notin bad
    check "/opt/safe" notin bad
    check "/usr/local/lib" notin bad

    # Edge cases: empty brackets, leading/trailing colon, dot traversal, safe /tmp_custom sibling
    check evaluateRunpaths(parseRunpathsFromReadelf(" 0x1d (RUNPATH) Library runpath: []")) == @["<empty>"]
    check evaluateRunpaths([":/usr/lib"]) == @["<empty>"]
    check evaluateRunpaths(["/usr/lib:"]) == @["<empty>"]
    check evaluateRunpaths(["", "/usr/lib"]) == @["<empty>"]
    check evaluateRunpaths(["/usr/lib/../tmp", "/opt/./lib", "$ORIGIN", "/tmp_custom/lib"]) == @[
      "/usr/lib/../tmp", "/opt/./lib", "$ORIGIN"
    ]
    check evaluateRunpaths(["/usr/lib", "/usr/local/lib", "/opt/pg/lib"]).len == 0

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

          # 2. Unsafe RPATH/RUNPATH (. /tmp /var/tmp ::)
          if findExe("readelf").len > 0:
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
            check "SECURITY VIOLATION" in rpAudit.errorMessage

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

          # Explicit opt-in -> passes
          writeFile(dlDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": true}""")
          check auditBinarySymbols(dlSo, dlDir)

          # Malformed non-bool allowDynamicLoader -> rejected
          writeFile(dlDir / "pgxext.json", """{"version": "0.1.0", "allowDynamicLoader": "yes"}""")
          check not auditBinarySymbols(dlSo, dlDir)
        finally:
          if dirExists(tmpDir):
            removeDir(tmpDir)
