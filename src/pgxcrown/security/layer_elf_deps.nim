## Layer 2: ELF dynamic linker & runpath fence (`readelf -d`).
## Enforces zero unapproved DT_NEEDED dependencies and zero DT_RPATH/DT_RUNPATH entries.

import std/[os, osproc, sets, strutils]
import ./policy

const
  AllowedRuntimeLibraries*: array[8, string] = [
    "libc.so.6",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libgcc_s.so.1",
    "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1",
    "linux-vdso.so.1"
  ]

proc addUnique(target: var seq[string], seen: var HashSet[string], item: string) {.inline.} =
  if item notin seen:
    seen.incl(item)
    target.add(item)

proc extractDynamicBracketValue(rawLine: string): (bool, string) =
  let openIdx = rawLine.find('[')
  let closeIdx = rawLine.rfind(']')
  if openIdx >= 0 and closeIdx > openIdx:
    return (true, rawLine[openIdx + 1 ..< closeIdx])
  let colonIdx = rawLine.find(':')
  if colonIdx >= 0 and colonIdx + 1 < rawLine.len:
    return (true, rawLine[colonIdx + 1 .. ^1].strip())
  (false, "")

proc parseRunpathsFromReadelf*(readelfOutput: string): seq[string] =
  ## Extracts raw RPATH/RUNPATH entries from `readelf -d` dynamic section output.
  result = @[]
  for rawLine in readelfOutput.splitLines():
    let upper = rawLine.toUpperAscii()
    if "(RPATH)" notin upper and "(RUNPATH)" notin upper:
      continue
    let (ok, rawPaths) = extractDynamicBracketValue(rawLine)
    if not ok:
      continue
    if rawPaths.len == 0:
      result.add("")
    else:
      for entry in rawPaths.split(':'):
        result.add(entry)

proc evaluateRunpaths*(entries: openArray[string]): seq[string] =
  ## Rejects ALL RPATH/RUNPATH entries unconditionally (even `pkglibdir` or `/usr/lib`),
  ## mapping empty elements to `<empty>`.
  result = @[]
  var seen = initHashSet[string]()
  for raw in entries:
    for entry in raw.split(':'):
      let label = if entry.len == 0: "<empty>" else: entry
      addUnique(result, seen, label)

proc auditElfRunpath*(soPath: string): seq[string] =
  ## Inspects ELF `RPATH`/`RUNPATH` entries via `readelf -d` on Linux.
  when defined(linux):
    if not fileExists(soPath) or findExe("readelf").len == 0:
      return @[]
    let (output, exitCode) = execCmdEx("readelf -d " & quoteShell(soPath))
    if exitCode != 0:
      return @[]
    return evaluateRunpaths(parseRunpathsFromReadelf(output))
  else:
    return @[]

proc parseNeededLibrariesFromReadelf*(readelfOutput: string): seq[string] =
  ## Extracts `DT_NEEDED` shared library names from `readelf -d` dynamic section output.
  result = @[]
  var seen = initHashSet[string]()
  for rawLine in readelfOutput.splitLines():
    if "(NEEDED)" notin rawLine.toUpperAscii():
      continue
    let (ok, libVal) = extractDynamicBracketValue(rawLine)
    if not ok:
      continue
    let cleaned = libVal.strip()
    if cleaned.len > 0:
      addUnique(result, seen, cleaned)

proc evaluateNeededLibraries*(neededLibs: openArray[string], policy: SecurityAuditPolicy): seq[string] =
  ## Returns any `DT_NEEDED` dependency outside `AllowedRuntimeLibraries`
  ## (`libdl.so.2` is permitted only when `policy.allowDynamicLoader == true`).
  result = @[]
  var allowed = toHashSet(AllowedRuntimeLibraries)
  if policy.allowDynamicLoader:
    allowed.incl("libdl.so.2")
  var seen = initHashSet[string]()
  for rawLib in neededLibs:
    let libName = rawLib.strip()
    if libName.len == 0:
      continue
    if libName notin allowed:
      addUnique(result, seen, libName)

proc auditElfNeededLibraries*(soPath: string, policy: SecurityAuditPolicy): seq[string] =
  ## Inspects ELF `DT_NEEDED` dependencies via `readelf -d` on Linux.
  when defined(linux):
    if not fileExists(soPath) or findExe("readelf").len == 0:
      return @[]
    let (output, exitCode) = execCmdEx("readelf -d " & quoteShell(soPath))
    if exitCode != 0:
      return @[]
    return evaluateNeededLibraries(parseNeededLibrariesFromReadelf(output), policy)
  else:
    return @[]

proc runElfDepsCheck(ctx: AuditContext): LayerReport =
  result = LayerReport(layerId: "elf_deps", kind: slkElfDeps, mandatory: true, passed: false)
  if not fileExists(ctx.soPath):
    result.findings.add(SecurityFinding(
      layerId: "elf_deps",
      code: "BINARY_NOT_FOUND",
      severity: sevError,
      message: "❌ [SECURITY AUDIT FAILED] Binary artifact not found: " & ctx.soPath
    ))
    return

  when defined(linux):
    if findExe("readelf").len == 0:
      result.findings.add(SecurityFinding(
        layerId: "elf_deps",
        code: "READELF_NOT_FOUND",
        severity: sevError,
        message: "❌ [SECURITY AUDIT FAILED] 'readelf' utility not found. Please install binutils to run ELF dependency audits."
      ))
      return

    let (reOut, reCode) = execCmdEx("readelf -d " & quoteShell(ctx.soPath))
    if reCode != 0:
      result.findings.add(SecurityFinding(
        layerId: "elf_deps",
        code: "READELF_EXEC_FAILED",
        severity: sevError,
        message: "❌ [SECURITY AUDIT FAILED] 'readelf' failed to inspect " & ctx.soPath & ": " & reOut.strip()
      ))
      return

    let badRunpaths = evaluateRunpaths(parseRunpathsFromReadelf(reOut))
    for rp in badRunpaths:
      result.findings.add(SecurityFinding(
        layerId: "elf_deps",
        code: "FORBIDDEN_RPATH",
        severity: sevError,
        subject: rp,
        message: "❌ [SECURITY VIOLATION] ELF RPATH/RUNPATH entries are forbidden in " &
          ctx.soPath & ": '" & rp & "'",
        hint: "Remove -Wl,-rpath / RPATH / RUNPATH linker flags; extensions must embed zero search paths."
      ))

    let badNeeded = evaluateNeededLibraries(parseNeededLibrariesFromReadelf(reOut), ctx.policy)
    for dep in badNeeded:
      let hintMsg =
        if dep == "libdl.so.2" and not ctx.policy.allowDynamicLoader:
          "Set \"allowDynamicLoader\": true in pgxext.json to explicitly permit libdl.so.2."
        else:
          "Only minimal OS C/math runtime libraries are permitted."
      result.findings.add(SecurityFinding(
        layerId: "elf_deps",
        code: "UNAPPROVED_DT_NEEDED",
        severity: sevError,
        subject: dep,
        message: "❌ [SECURITY VIOLATION] Unapproved DT_NEEDED shared library dependency detected in " &
          ctx.soPath & ": '" & dep & "'" &
          (if dep == "libdl.so.2" and not ctx.policy.allowDynamicLoader: " (set \"allowDynamicLoader\": true in pgxext.json)" else: ""),
        hint: hintMsg
      ))

    result.passed = (badRunpaths.len == 0 and badNeeded.len == 0)
  else:
    result.passed = true

proc elfDepsSecurityLayer*(): SecurityLayer =
  ## Constructs the mandatory Layer 2 ELF dynamic linker & runpath fence layer.
  SecurityLayer(
    id: "elf_deps",
    kind: slkElfDeps,
    mandatory: true,
    check: runElfDepsCheck
  )
