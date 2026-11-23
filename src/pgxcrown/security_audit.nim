## Static/stdlib-only ELF binary & symbol security auditor for pgxcrown extensions and hooks.
## Designed to compile cleanly with `musl-gcc --passL:-static` as part of `pgxtool`.

import std/[os, osproc, sets, strutils]

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

  DynamicLoaderSymbols*: array[6, string] = [
    "dlopen", "dlsym", "dlvsym", "dlmopen", "dlclose", "dlerror"
  ]

type
  SecurityAuditPolicy* = object
    ## Security audit policy controlling optional exemptions such as dynamic loading.
    allowDynamicLoader*: bool = false

  AuditResult* = object
    ## Structured outcome of symbol and ELF RUNPATH/RPATH security evaluation.
    passed*: bool
    blockedSymbols*: seq[string]
    blockedOsSymbols*: seq[string]
    blockedLoaderSymbols*: seq[string]
    allowedLoaderSymbols*: seq[string]
    unsafeRunpaths*: seq[string]
    errors*: seq[string]
    errorMessage*: string

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

proc evaluateSymbols*(undefSyms: openArray[string], policy: SecurityAuditPolicy): AuditResult =
  ## Evaluates undefined symbols against `BlockedOsSymbols` and `DynamicLoaderSymbols`.
  let blockedOsSet = toHashSet(BlockedOsSymbols)
  let loaderSet = toHashSet(DynamicLoaderSymbols)

  var seenBlocked = initHashSet[string]()
  var seenOs = initHashSet[string]()
  var seenLoaderBlocked = initHashSet[string]()
  var seenLoaderAllowed = initHashSet[string]()

  for rawSym in undefSyms:
    let symName = stripSymbolVersion(rawSym)
    if symName.len == 0:
      continue
    if symName in blockedOsSet:
      addUnique(result.blockedOsSymbols, seenOs, symName)
      addUnique(result.blockedSymbols, seenBlocked, symName)
    elif symName in loaderSet:
      if policy.allowDynamicLoader:
        addUnique(result.allowedLoaderSymbols, seenLoaderAllowed, symName)
      else:
        addUnique(result.blockedLoaderSymbols, seenLoaderBlocked, symName)
        addUnique(result.blockedSymbols, seenBlocked, symName)

  if result.blockedOsSymbols.len > 0:
    result.errors.add(
      "❌ [SECURITY VIOLATION] Restricted OS system calls detected: " &
      result.blockedOsSymbols.join(", ")
    )
  if result.blockedLoaderSymbols.len > 0:
    result.errors.add(
      "❌ [SECURITY VIOLATION] Dynamic library loader symbols detected (" &
      result.blockedLoaderSymbols.join(", ") &
      "). Blocked by default; set \"allowDynamicLoader\": true in pgxext.json to explicitly opt in."
    )

  result.errorMessage = result.errors.join("\n")
  result.passed = result.errors.len == 0

proc parseRunpathsFromReadelf*(readelfOutput: string): seq[string] =
  ## Extracts raw RPATH/RUNPATH entries from `readelf -d` dynamic section output.
  result = @[]
  for rawLine in readelfOutput.splitLines():
    let upper = rawLine.toUpperAscii()
    if "(RPATH)" notin upper and "(RUNPATH)" notin upper:
      continue
    let openIdx = rawLine.find('[')
    let closeIdx = rawLine.rfind(']')
    var rawPaths = ""
    if openIdx >= 0 and closeIdx > openIdx:
      rawPaths = rawLine[openIdx + 1 ..< closeIdx]
    else:
      let colonIdx = rawLine.find(':')
      if colonIdx >= 0 and colonIdx + 1 < rawLine.len:
        rawPaths = rawLine[colonIdx + 1 .. ^1].strip()
      else:
        continue

    if rawPaths.len == 0:
      result.add("")
    else:
      for entry in rawPaths.split(':'):
        result.add(entry)

proc isUnsafeRunpathEntry*(entry: string): bool =
  ## Returns true when an RPATH/RUNPATH entry is empty, relative, contains dot segments,
  ## or points inside shared writable temporary directories.
  if entry.len == 0 or not entry.startsWith("/"):
    return true
  for seg in entry.split('/'):
    if seg == "." or seg == "..":
      return true
  let norm = normalizedPath(entry)
  for prefix in ["/tmp", "/var/tmp", "/dev/shm", "/run/shm"]:
    if entry == prefix or entry.startsWith(prefix & "/") or
       norm == prefix or norm.startsWith(prefix & "/"):
      return true
  false

proc evaluateRunpaths*(entries: openArray[string]): seq[string] =
  ## Returns deduplicated unsafe RPATH/RUNPATH entries (representing empty entries as `<empty>`).
  result = @[]
  var seen = initHashSet[string]()
  for raw in entries:
    for entry in raw.split(':'):
      if isUnsafeRunpathEntry(entry):
        let label = if entry.len == 0: "<empty>" else: entry
        addUnique(result, seen, label)

proc auditElfRunpath*(soPath: string): seq[string] =
  ## Inspects ELF `RPATH`/`RUNPATH` entries via `readelf -d` when running on Linux
  ## and returns any unsafe entries found.
  when defined(linux):
    if not fileExists(soPath) or findExe("readelf").len == 0:
      return @[]
    let (output, exitCode) = execCmdEx("readelf -d " & quoteShell(soPath))
    if exitCode != 0:
      return @[]
    return evaluateRunpaths(parseRunpathsFromReadelf(output))
  else:
    return @[]

proc auditBinaryFile*(soPath: string, policy: SecurityAuditPolicy): AuditResult =
  ## Audits a compiled extension or hook shared library for blocked OS/loader symbols
  ## and unsafe ELF `RPATH`/`RUNPATH` entries under `policy`.
  if not fileExists(soPath):
    result.errors.add("❌ [SECURITY AUDIT FAILED] Binary artifact not found: " & soPath)
    result.errorMessage = result.errors.join("\n")
    result.passed = false
    return

  if findExe("nm").len == 0:
    result.errors.add("❌ [SECURITY AUDIT FAILED] 'nm' utility not found. Please install binutils to run security audits.")
    result.errorMessage = result.errors.join("\n")
    result.passed = false
    return

  when defined(macosx):
    let nmCmd = "nm -u " & quoteShell(soPath)
  else:
    let nmCmd = "nm -D -u " & quoteShell(soPath)

  let (nmOut, nmCode) = execCmdEx(nmCmd)
  if nmCode != 0:
    result.errors.add("❌ [SECURITY AUDIT FAILED] 'nm' failed to inspect " & soPath & ": " & nmOut.strip())
    result.errorMessage = result.errors.join("\n")
    result.passed = false
    return

  var undefSyms = parseUndefinedSymbolsFromNm(nmOut)
  when defined(macosx):
    var expanded: seq[string] = @[]
    for s in undefSyms:
      expanded.add(s)
      if s.startsWith("_") and s.len > 1:
        expanded.add(s[1..^1])
    undefSyms = expanded

  result = evaluateSymbols(undefSyms, policy)

  let badRunpaths = auditElfRunpath(soPath)
  if badRunpaths.len > 0:
    result.unsafeRunpaths = badRunpaths
    result.errors.add(
      "❌ [SECURITY VIOLATION] Unsafe ELF RPATH/RUNPATH entries detected in " &
      soPath & ": " & badRunpaths.join(", ")
    )
    result.errorMessage = result.errors.join("\n")
    result.passed = false
