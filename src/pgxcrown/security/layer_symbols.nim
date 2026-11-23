## Layer 1: ELF undefined symbol sandbox (`nm -D -u` / `nm -u`).
## Delimited strictly to OS system-call and dynamic-loader symbol auditing.

import std/[os, osproc, sets, strutils]
import ./policy

const
  BlockedOsSymbols*: array[72, string] = [
    # Exec / process / syscall bypass
    "system", "execve", "execv", "execl", "execlp", "execvp", "execvpe",
    "fexecve", "execveat", "popen", "pclose", "fork", "vfork", "clone", "clone3",
    "posix_spawn", "posix_spawnp", "syscall", "wordexp",
    # Signals / trace / memory / privilege escalation / kernel
    "kill", "killpg", "tkill", "tgkill", "ptrace",
    "process_vm_readv", "process_vm_writev", "mprotect", "pkey_mprotect", "prctl",
    "setuid", "setgid", "seteuid", "setegid", "setreuid", "setregid",
    "setresuid", "setresgid", "setgroups", "initgroups",
    "chroot", "pivot_root", "mount", "umount", "umount2",
    "unshare", "setns", "memfd_create",
    "init_module", "finit_module", "delete_module", "kexec_load", "reboot", "capset",
    # Destructive / permission / special filesystem ops
    "unlink", "unlinkat", "remove", "rmdir",
    "chmod", "fchmod", "fchmodat",
    "chown", "fchown", "lchown", "fchownat",
    "symlink", "symlinkat", "link", "linkat",
    "mknod", "mknodat", "truncate", "ftruncate"
  ]

  DynamicLoaderSymbols*: array[20, string] = [
    # POSIX / glibc dynamic loader
    "dlopen", "dlsym", "dlvsym", "dlmopen", "dlclose", "dlerror",
    # PostgreSQL internal shared-library loaders
    "load_external_function", "lookup_external_function", "load_file",
    "internal_load_library", "pg_dlopen", "pg_dlsym", "pg_dlclose", "pg_dlerror",
    # Windows DLL loaders
    "LoadLibraryA", "LoadLibraryW", "LoadLibraryExA", "LoadLibraryExW",
    "GetProcAddress", "FreeLibrary"
  ]

proc isHexAddress(s: string): bool {.inline.} =
  if s.len < 4:
    return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc stripSymbolVersion*(sym: string): string {.inline.} =
  ## Strips `@...` and `@@...` ELF symbol version suffixes from a symbol name.
  let cleaned = sym.strip()
  let atIdx = cleaned.find('@')
  if atIdx >= 0: cleaned[0 ..< atIdx] else: cleaned

proc parseUndefinedSymbolsFromNm*(nmOutput: string): seq[string] =
  ## Parses undefined symbol names from `nm -D -u`, `nm -u`, or `nm -D` output,
  ## normalizing `@GLIBC_...` / `@@GLIBC_...` suffixes cleanly.
  result = @[]
  var seen = initHashSet[string]()
  for rawLine in nmOutput.splitLines():
    let parts = rawLine.splitWhitespace()
    if parts.len == 0:
      continue
    var symToken = ""
    if parts.len == 1:
      if parts[0].endsWith(":"):
        continue
      symToken = parts[0]
    elif parts[0] in ["U", "u", "w", "v"]:
      symToken = parts[1]
    elif parts.len >= 3 and parts[1] in ["U", "u", "w", "v"]:
      symToken = if isHexAddress(parts[0]): parts[2] else: parts[0]
    elif parts.len == 2 and parts[1] in ["U", "u", "w", "v"]:
      symToken = parts[0]
    else:
      continue

    let baseName = stripSymbolVersion(symToken)
    if baseName.len > 0 and baseName notin seen:
      seen.incl(baseName)
      result.add(baseName)

proc addUnique(target: var seq[string], seen: var HashSet[string], item: string) {.inline.} =
  if item notin seen:
    seen.incl(item)
    target.add(item)

proc collectSymbolEvaluation(
  undefSyms: openArray[string],
  policy: SecurityAuditPolicy
): tuple[
  blockedOs: seq[string],
  blockedLoader: seq[string],
  allowedLoader: seq[string],
  blockedAll: seq[string],
  findings: seq[SecurityFinding]
] =
  let blockedOsSet = toHashSet(BlockedOsSymbols)
  let loaderSet = toHashSet(DynamicLoaderSymbols)

  var seenOs = initHashSet[string]()
  var seenLoaderBlocked = initHashSet[string]()
  var seenLoaderAllowed = initHashSet[string]()
  var seenAll = initHashSet[string]()

  for rawSym in undefSyms:
    let symName = stripSymbolVersion(rawSym)
    if symName.len == 0:
      continue
    if symName in blockedOsSet:
      addUnique(result.blockedOs, seenOs, symName)
      addUnique(result.blockedAll, seenAll, symName)
    elif symName in loaderSet:
      if policy.allowDynamicLoader:
        addUnique(result.allowedLoader, seenLoaderAllowed, symName)
      else:
        addUnique(result.blockedLoader, seenLoaderBlocked, symName)
        addUnique(result.blockedAll, seenAll, symName)

  for sym in result.blockedOs:
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "BLOCKED_OS_SYMBOL",
      severity: sevError,
      subject: sym,
      message: "❌ [SECURITY VIOLATION] Restricted OS system call detected: '" & sym & "'",
      hint: "Remove restricted OS/process/filesystem FFI calls."
    ))
  for sym in result.blockedLoader:
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "BLOCKED_DYNAMIC_LOADER",
      severity: sevError,
      subject: sym,
      message: "❌ [SECURITY VIOLATION] Dynamic library loader symbol detected ('" & sym &
        "'). Blocked by default; set \"allowDynamicLoader\": true in pgxext.json to explicitly opt in.",
      hint: "Set \"allowDynamicLoader\": true in pgxext.json only if dynamic loading is strictly required."
    ))
  for sym in result.allowedLoader:
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "ALLOWED_DYNAMIC_LOADER",
      severity: sevInfo,
      subject: sym,
      message: "ℹ️  Dynamic loader symbol explicitly allowed via pgxext.json: '" & sym & "'",
      hint: ""
    ))

proc evaluateSymbols*(undefSyms: openArray[string], policy: SecurityAuditPolicy): PipelineReport =
  ## Evaluates undefined symbols against `BlockedOsSymbols` and `DynamicLoaderSymbols`.
  let eval = collectSymbolEvaluation(undefSyms, policy)
  result.blockedOsSymbols = eval.blockedOs
  result.blockedLoaderSymbols = eval.blockedLoader
  result.allowedLoaderSymbols = eval.allowedLoader
  result.blockedSymbols = eval.blockedAll

  if eval.blockedOs.len > 0:
    result.errors.add(
      "❌ [SECURITY VIOLATION] Restricted OS system calls detected: " &
      eval.blockedOs.join(", ")
    )
  if eval.blockedLoader.len > 0:
    result.errors.add(
      "❌ [SECURITY VIOLATION] Dynamic library loader symbols detected (" &
      eval.blockedLoader.join(", ") &
      "). Blocked by default; set \"allowDynamicLoader\": true in pgxext.json to explicitly opt in."
    )

  let layerPassed = result.errors.len == 0
  result.layerReports.add(LayerReport(
    layerId: "symbols",
    kind: slkSymbols,
    mandatory: true,
    passed: layerPassed,
    findings: eval.findings
  ))
  result.errorMessage = result.errors.join("\n")
  result.passed = layerPassed

proc runSymbolsCheck(ctx: AuditContext): LayerReport =
  result = LayerReport(layerId: "symbols", kind: slkSymbols, mandatory: true, passed: false)
  if not fileExists(ctx.soPath):
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "BINARY_NOT_FOUND",
      severity: sevError,
      message: "❌ [SECURITY AUDIT FAILED] Binary artifact not found: " & ctx.soPath
    ))
    return

  if findExe("nm").len == 0:
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "NM_NOT_FOUND",
      severity: sevError,
      message: "❌ [SECURITY AUDIT FAILED] 'nm' utility not found. Please install binutils to run security audits."
    ))
    return

  when defined(macosx):
    let nmCmd = "nm -u " & quoteShell(ctx.soPath)
  else:
    let nmCmd = "nm -D -u " & quoteShell(ctx.soPath)

  let (nmOut, nmCode) = execCmdEx(nmCmd)
  if nmCode != 0:
    result.findings.add(SecurityFinding(
      layerId: "symbols",
      code: "NM_EXEC_FAILED",
      severity: sevError,
      message: "❌ [SECURITY AUDIT FAILED] 'nm' failed to inspect " & ctx.soPath & ": " & nmOut.strip()
    ))
    return

  var undefSyms = parseUndefinedSymbolsFromNm(nmOut)
  when defined(macosx):
    var expanded: seq[string] = @[]
    for s in undefSyms:
      expanded.add(s)
      if s.startsWith("_") and s.len > 1:
        expanded.add(s[1..^1])
    undefSyms = expanded

  let eval = collectSymbolEvaluation(undefSyms, ctx.policy)
  result.findings = eval.findings
  result.passed = eval.blockedAll.len == 0

proc symbolsSecurityLayer*(): SecurityLayer =
  ## Constructs the mandatory Layer 1 undefined-symbol sandbox security layer.
  SecurityLayer(
    id: "symbols",
    kind: slkSymbols,
    mandatory: true,
    check: runSymbolsCheck
  )
