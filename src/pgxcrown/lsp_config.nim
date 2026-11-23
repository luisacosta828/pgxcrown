## Pure-stdlib LSP / IDE `nim.cfg` generation and synchronization for pgxcrown projects.
## Uses only Nim standard library modules so static musl builds of `pgxtool` remain portable.

import std/[algorithm, os, osproc, strutils]

const
  ManagedBeginMarker* = "# BEGIN PGXCROWN MANAGED"
  ManagedEndMarker* = "# END PGXCROWN MANAGED"
  LspSupportedPgVersions* = [14, 15, 16, 17, 18]
  LspDefaultPgVersion* = 18

proc parsePgTargetVersion*(verStr: string): int =
  ## Parses a PostgreSQL target version string (`14`..`18` or `latest`), returning `-1` if invalid.
  let s = verStr.toLowerAscii().strip()
  if s == "latest":
    return LspDefaultPgVersion
  try:
    let v = parseInt(s)
    if v in LspSupportedPgVersions:
      return v
  except ValueError:
    discard
  return -1

proc escapeNimCfgString*(val: string): string =
  ## Escapes backslashes and double quotes for Nim `nim.cfg` string literals.
  result = newStringOfCap(val.len)
  for ch in val:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\r', '\n': discard
    else: result.add(ch)

proc renderProjectNimCfg*(pgxcrownSrcDir, pgIncServer, pgIncBase: string, pgVersion: int): string =
  ## Renders the managed `nim.cfg` block for `nim check` and `nimlangserver`.
  ## Never emits `--app:lib` or `--passL:"-Wl,--wrap=malloc"`.
  var lines: seq[string] = @[ManagedBeginMarker]

  let cleanSrc = pgxcrownSrcDir.strip()
  if cleanSrc.len > 0:
    lines.add("--path:\"" & escapeNimCfgString(cleanSrc) & "\"")

  lines.add("--path:\"src\"")
  lines.add("--path:\"private\"")
  lines.add("--mm:arc")

  if pgVersion > 0:
    lines.add("-d:pgTargetVersion=" & $pgVersion)

  let cleanIncServer = pgIncServer.strip()
  if cleanIncServer.len > 0:
    lines.add("--cincludes:\"" & escapeNimCfgString(cleanIncServer) & "\"")

  let cleanIncBase = pgIncBase.strip()
  if cleanIncBase.len > 0 and cleanIncBase != cleanIncServer:
    lines.add("--cincludes:\"" & escapeNimCfgString(cleanIncBase) & "\"")

  lines.add(ManagedEndMarker)
  result = lines.join("\n") & "\n"

proc mergeNimCfgContent*(existingContent, managedBlock: string): string =
  ## Updates only the `# BEGIN PGXCROWN MANAGED` .. `# END PGXCROWN MANAGED` block,
  ## preserving any user lines outside the managed markers.
  let normManaged = managedBlock.replace("\r\n", "\n").strip(leading = false, trailing = true, chars = {'\n'})
  let managedLines = if normManaged.len > 0: normManaged.split('\n') else: @[]

  let normExisting = existingContent.replace("\r\n", "\n")
  if normExisting.strip().len == 0:
    return (if managedLines.len > 0: managedLines.join("\n") & "\n" else: "")

  var existingLines = normExisting.split('\n')
  if existingLines.len > 0 and existingLines[^1] == "":
    existingLines.setLen(existingLines.len - 1)

  var beginIdx = -1
  var endIdx = -1
  for i, line in existingLines:
    if line.strip() == ManagedBeginMarker:
      beginIdx = i
      break

  if beginIdx >= 0:
    for i in beginIdx ..< existingLines.len:
      if existingLines[i].strip() == ManagedEndMarker:
        endIdx = i
        break

  var outLines: seq[string] = @[]
  if beginIdx >= 0 and endIdx >= beginIdx:
    if beginIdx > 0:
      outLines.add(existingLines[0 ..< beginIdx])
    outLines.add(managedLines)
    if endIdx + 1 < existingLines.len:
      outLines.add(existingLines[(endIdx + 1) .. ^1])
  elif beginIdx >= 0:
    if beginIdx > 0:
      outLines.add(existingLines[0 ..< beginIdx])
    outLines.add(managedLines)
  else:
    outLines.add(existingLines)
    if outLines.len > 0 and outLines[^1].strip().len > 0:
      outLines.add("")
    outLines.add(managedLines)

  result = outLines.join("\n") & "\n"

proc writeProjectNimCfg*(projectDir, pgxcrownSrcDir, pgIncServer, pgIncBase: string, pgVersion: int): string {.discardable.} =
  ## Writes or updates `<projectDir>/nim.cfg` while preserving user-managed lines.
  createDir(projectDir)
  let cfgPath = projectDir / "nim.cfg"
  let managedBlock = renderProjectNimCfg(pgxcrownSrcDir, pgIncServer, pgIncBase, pgVersion)
  let existing = if fileExists(cfgPath): readFile(cfgPath) else: ""
  let merged = mergeNimCfgContent(existing, managedBlock)
  if existing != merged or not fileExists(cfgPath):
    writeFile(cfgPath, merged)
  result = cfgPath

proc isValidPgxcrownSrcDir(dir: string): bool {.inline.} =
  dir.len > 0 and dirExists(dir / "pgxcrown") and fileExists(dir / "pgxcrown.nim")

proc scanNimblePkgCache(pkgsDir: string): string =
  if not dirExists(pkgsDir):
    return ""
  var candidates: seq[string] = @[]
  for kind, path in walkDir(pkgsDir):
    if kind == pcDir:
      let base = extractFilename(path)
      if base == "pgxcrown" or base.startsWith("pgxcrown-"):
        if isValidPgxcrownSrcDir(path):
          candidates.add(path)
  if candidates.len == 0:
    return ""
  candidates.sort(order = SortOrder.Descending)
  candidates[0]

proc discoverPgxcrownSrcDir*(extraPkgDirs: openArray[string] = @[]): string =
  ## Resolves the active `pgxcrown` source root (containing `pgxcrown.nim` and `pgxcrown/`).
  let envSrc = getEnv("PGXCROWN_SRC_DIR", "").strip()
  if isValidPgxcrownSrcDir(envSrc):
    return envSrc

  let repoSrc = currentSourcePath.parentDir.parentDir
  if isValidPgxcrownSrcDir(repoSrc):
    return repoSrc

  var resolved = getAppFilename()
  when not defined(windows):
    var hops = 0
    while resolved.len > 0 and hops < 8 and symlinkExists(resolved):
      inc hops
      try:
        let target = expandSymlink(resolved)
        resolved = if target.isAbsolute: target else: resolved.parentDir / target
      except OSError:
        break
  if resolved.len > 0:
    let pkgRoot = resolved.parentDir.parentDir
    if isValidPgxcrownSrcDir(pkgRoot):
      return pkgRoot

  var searchDirs: seq[string] = @[]
  for extra in extraPkgDirs:
    if extra.len > 0:
      searchDirs.add(extra)

  let nimbleEnv = getEnv("NIMBLE_DIR", "").strip()
  if nimbleEnv.len > 0:
    searchDirs.add(nimbleEnv / "pkgs2")
    searchDirs.add(nimbleEnv / "pkgs")

  let homeNimble = getHomeDir() / ".nimble"
  searchDirs.add(homeNimble / "pkgs2")
  searchDirs.add(homeNimble / "pkgs")
  searchDirs.add("/opt/nimble/pkgs2")
  searchDirs.add("/opt/nimble/pkgs")

  for pkgsDir in searchDirs:
    let found = scanNimblePkgCache(pkgsDir)
    if found.len > 0:
      return found

  return ""

proc parsePgMajorVersion*(output: string): int =
  ## Extracts the major PostgreSQL version number from `pg_config --version` output.
  for token in output.splitWhitespace():
    var digits = ""
    for ch in token:
      if ch >= '0' and ch <= '9':
        digits.add(ch)
      else:
        break
    if digits.len > 0:
      try:
        let v = parseInt(digits)
        if v >= 10:
          return v
      except ValueError:
        discard
  return 0

proc execPgConfigFlag(pgConfigExe, flag: string): string =
  if pgConfigExe.len == 0:
    return ""
  try:
    let (output, exitCode) = execCmdEx(quoteShell(pgConfigExe) & " " & flag)
    if exitCode == 0:
      return output.strip()
  except CatchableError:
    discard
  return ""

proc findDefaultPgConfig(): string =
  let exe = findExe("pg_config")
  if exe.len > 0:
    return exe
  when defined(windows):
    for ver in countdown(25, 14):
      let candidate = r"C:\Program Files\PostgreSQL\" & $ver & r"\bin\pg_config.exe"
      if fileExists(candidate):
        return candidate
  return ""

proc findVersionedPgConfig(pgVersion: int): string =
  if pgVersion <= 0:
    return findDefaultPgConfig()

  when defined(windows):
    let winCand = r"C:\Program Files\PostgreSQL\" & $pgVersion & r"\bin\pg_config.exe"
    if fileExists(winCand):
      return winCand
  else:
    let candidates = [
      "/usr/lib/postgresql/" & $pgVersion & "/bin/pg_config",
      "/usr/pgsql-" & $pgVersion & "/bin/pg_config",
      "/opt/homebrew/opt/postgresql@" & $pgVersion & "/bin/pg_config",
      "/usr/local/opt/postgresql@" & $pgVersion & "/bin/pg_config"
    ]
    for cand in candidates:
      if fileExists(cand):
        return cand

  let defExe = findDefaultPgConfig()
  if defExe.len > 0:
    let verOut = execPgConfigFlag(defExe, "--version")
    if parsePgMajorVersion(verOut) == pgVersion:
      return defExe
  return ""

proc discoverPgLspEnv*(pgVersionOverride: int = 0): tuple[pgVersion: int, pgIncServer: string, pgIncBase: string] =
  ## Discovers PostgreSQL major version and header include paths cleanly without failing
  ## when host PostgreSQL headers are absent (e.g., standalone Docker-only CLI hosts).
  var pgVer = pgVersionOverride
  var pgConfigExe = ""

  if pgVersionOverride > 0:
    pgConfigExe = findVersionedPgConfig(pgVersionOverride)
  else:
    pgConfigExe = findDefaultPgConfig()
    if pgConfigExe.len > 0:
      let parsed = parsePgMajorVersion(execPgConfigFlag(pgConfigExe, "--version"))
      if parsed in LspSupportedPgVersions:
        pgVer = parsed
      elif parsed > 0:
        pgVer = parsed
    if pgVer <= 0:
      pgVer = LspDefaultPgVersion

  var incServer = ""
  var incBase = ""

  if pgConfigExe.len > 0:
    let rawServer = execPgConfigFlag(pgConfigExe, "--includedir-server")
    if rawServer.len > 0 and dirExists(rawServer):
      incServer = rawServer
    let rawBase = execPgConfigFlag(pgConfigExe, "--includedir")
    if rawBase.len > 0 and dirExists(rawBase):
      incBase = rawBase
  elif pgVersionOverride > 0:
    when not defined(windows):
      let fallbackServer = "/usr/include/postgresql/" & $pgVersionOverride & "/server"
      if dirExists(fallbackServer):
        incServer = fallbackServer
        if dirExists("/usr/include/postgresql"):
          incBase = "/usr/include/postgresql"

  (pgVersion: pgVer, pgIncServer: incServer, pgIncBase: incBase)

proc syncProjectNimCfg*(projectDir: string, pgVersionOverride: int = 0): tuple[
  cfgPath, pgxcrownSrcDir, pgIncServer, pgIncBase: string, pgVersion: int
] =
  ## Discovers `pgxcrown` and PostgreSQL paths and updates `<projectDir>/nim.cfg`.
  let srcDir = discoverPgxcrownSrcDir()
  let pgEnv = discoverPgLspEnv(pgVersionOverride)
  let cfgPath = writeProjectNimCfg(projectDir, srcDir, pgEnv.pgIncServer, pgEnv.pgIncBase, pgEnv.pgVersion)
  (
    cfgPath: cfgPath,
    pgxcrownSrcDir: srcDir,
    pgIncServer: pgEnv.pgIncServer,
    pgIncBase: pgEnv.pgIncBase,
    pgVersion: pgEnv.pgVersion
  )
