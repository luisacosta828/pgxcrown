import std/[os, osproc, strutils, times]
import test_engine/[oci_driver, container_runner, diff_engine, test_discovery]

const
  ColReset = "\e[0m"
  ColRed = "\e[31m"
  ColGreen = "\e[32m"
  ColYellow = "\e[33m"
  ColCyan = "\e[36m"
  ColBold = "\e[1m"
  ColDim = "\e[2m"

type
  CompileCallback* = proc(entryPoint: string, targetVersion: int)
  SqlExecFn = proc(sqlPath: string): (string, int)

proc ensureTestDirectories(projectDir: string) =
  let sqlDir = projectDir / "tests" / "sql"
  let expDir = projectDir / "tests" / "expected"
  createDir(sqlDir)
  createDir(expDir)

proc isServerCrash(output: string): bool =
  let lower = output.toLowerAscii()
  return "server closed the connection unexpectedly" in lower or
         "terminating connection due to administrator command" in lower or
         "fatal:  database system is in recovery mode" in lower or
         "the database system is shutting down" in lower or
         "panic:" in lower

proc executeAndVerifyTestCases(
  testCases: seq[TestCase],
  bless: bool,
  verbose: bool,
  pgVersion: int,
  execSql: SqlExecFn
): bool =
  var passedCount = 0
  var failedCount = 0

  for tc in testCases:
    let startTime = epochTime()
    let (actualOutput, _) = execSql(tc.sqlPath)
    let elapsedMs = int((epochTime() - startTime) * 1000)

    if isServerCrash(actualOutput):
      echo "   • tests/sql/" & tc.name & ".sql ...... " & ColRed & "💥 SERVER CRASH DETECTED" & ColReset & " (" & $elapsedMs & "ms)"
      echo ColRed & "     PostgreSQL server crashed while executing test!" & ColReset
      echo ColDim & "     ┌─ [Crash Log] ───────────────────────────────────────────" & ColReset
      for line in actualOutput.strip.splitLines():
        echo ColDim & "     │ " & ColReset & line
      echo ColDim & "     └─────────────────────────────────────────────────────────" & ColReset
      inc failedCount
      continue

    if bless or not fileExists(tc.expectedPath):
      blessExpectedFile(tc.expectedPath, actualOutput)
      echo "   • tests/sql/" & tc.name & ".sql ...... " & ColYellow & "✨ BLESSED" & ColReset & " (" & $elapsedMs & "ms)"
      if verbose:
        echo ColDim & "     ┌─ [PostgreSQL Response] ──────────────────────────────────" & ColReset
        for line in actualOutput.strip.splitLines():
          echo ColDim & "     │ " & ColReset & line
        echo ColDim & "     └─────────────────────────────────────────────────────────" & ColReset
      inc passedCount
    else:
      let expectedContent = readFile(tc.expectedPath)
      let (matches, diffReport) = computeSimpleDiff(expectedContent, actualOutput)
      if matches:
        echo "   • tests/sql/" & tc.name & ".sql ...... " & ColGreen & "✅ PASSED" & ColReset & " (" & $elapsedMs & "ms)"
        if verbose:
          echo ColDim & "     ┌─ [PostgreSQL Output Verified] ───────────────────────────" & ColReset
          for line in actualOutput.strip.splitLines():
            echo ColDim & "     │ " & ColReset & line
          echo ColDim & "     └─────────────────────────────────────────────────────────" & ColReset
        inc passedCount
      else:
        echo "   • tests/sql/" & tc.name & ".sql ...... " & ColRed & "❌ FAILED" & ColReset & " (" & $elapsedMs & "ms)"
        echo "\n" & diffReport & "\n"
        inc failedCount

  echo "----------------------------------------------------------------------"
  if failedCount == 0:
    echo ColGreen & ColBold & "🎉 PG " & $pgVersion & " ALL TESTS PASSED (" & $passedCount & "/" & $testCases.len & ")" & ColReset
    return true
  else:
    echo ColRed & ColBold & "❌ PG " & $pgVersion & " FAILURES: " & $failedCount & " failed, " & $passedCount & " passed" & ColReset
    return false

proc runTestSuiteForVersion*(
  project: string,
  projectDir: string,
  docker: DockerDriver,
  pgVersion: int,
  bless: bool,
  keepContainer: bool,
  verbose: bool = false,
  isHook: bool = false,
  debug: bool = false,
  compileCb: CompileCallback = nil
): bool =
  let imageTag = getCanonicalImageTag(pgVersion)
  echo "\n" & ColCyan & ColBold & "======================================================================" & ColReset
  echo ColCyan & ColBold & "🐘 Pgxcrown Test Runner [" & imageTag & " — native in-container build & test]" & ColReset
  echo ColCyan & ColBold & "======================================================================" & ColReset

  var testCases = discoverTests(projectDir)
  if testCases.len == 0:
    echo "ℹ️  No test files found in " & (projectDir / "tests" / "sql") & "."
    echo "   Create a .sql script (e.g. tests/sql/01_basic.sql) to test your extension queries."
    return true

  let containerName = "pgxtool_sandbox_" & project & "_pg" & $pgVersion
  echo "🚀 [1/4] Starting PostgreSQL " & $pgVersion & " sandbox container (" & imageTag & ")..."
  let ctx = setupPgSandbox(docker, containerName, pgVersion)

  echo "📦 [2/4] Copying project '" & project & "' & compiling natively inside container..."
  if not ctx.buildAndInstallProjectInContainer(projectDir, project, isHook = isHook, debug = debug, verbose = verbose):
    if not keepContainer: ctx.cleanupSandbox()
    return false

  let testDb = "pgxtool_test_" & project
  echo "🗄️  [3/4] Creating clean database '" & testDb & "' and loading " & (if isHook: "hook" else: "extension") & "..."
  if not ctx.createCleanDatabase(testDb, project, isHook = isHook):
    if not keepContainer: ctx.cleanupSandbox()
    echo ColRed & "❌ Failed to create clean test database and load " & (if isHook: "hook." else: "extension.") & ColReset
    return false

  echo "🧪 [4/4] Executing SQL regression tests..."
  let allPassed = executeAndVerifyTestCases(
    testCases = testCases,
    bless = bless,
    verbose = verbose,
    pgVersion = pgVersion,
    execSql = proc(sqlPath: string): (string, int) = ctx.executeSqlInContainer(testDb, sqlPath)
  )

  if not keepContainer:
    echo "🧹 Cleaning up sandbox container..."
    ctx.cleanupSandbox()
  else:
    echo "ℹ️  Container '" & containerName & "' kept alive for debugging."
    echo "   PSQL : " & docker.binaryPath & " exec -it " & containerName & " psql -U postgres -d " & testDb
    echo "   Shell: " & docker.binaryPath & " exec -it -w " & quoteShell("/workspace/pgx/" & project) & " " & containerName & " bash"

  return allPassed

proc installProjectLocally(projectDir: string, project: string): bool =
  let srcDir = projectDir / "src"
  let installScript = srcDir / "install.sh"
  if fileExists(installScript):
    let (outp, code) = execCmdEx(quoteShell(installScript))
    if code != 0:
      echo ColRed & "❌ Failed to run install.sh:\n" & outp & ColReset
      return false
    return true

  let (libOut, libCode) = execCmdEx("pg_config --pkglibdir")
  let (shareOut, shareCode) = execCmdEx("pg_config --sharedir")
  if libCode != 0 or shareCode != 0:
    echo ColRed & "❌ Failed to locate local PostgreSQL directories via pg_config." & ColReset
    return false

  let pkglibdir = libOut.strip()
  let extdir = shareOut.strip() / "extension"
  createDir(pkglibdir)
  createDir(extdir)

  var soFile = srcDir / (project & ".so")
  if not fileExists(soFile):
    if fileExists(srcDir / project): soFile = srcDir / project
    elif fileExists(srcDir / ("lib" & project & ".so")): soFile = srcDir / ("lib" & project & ".so")
  if not fileExists(soFile):
    echo ColRed & "❌ Compiled shared library not found in " & srcDir & ColReset
    return false
  copyFile(soFile, pkglibdir / (project & ".so"))

  for kind, path in walkDir(srcDir):
    if kind == pcFile:
      let fn = extractFilename(path)
      if fn.endsWith(".control") or fn.endsWith(".sql"):
        copyFile(path, extdir / fn)
  return true

proc runLocalTestSuite(
  project: string,
  projectDir: string,
  pgVersion: int,
  bless: bool,
  verbose: bool,
  isHook: bool,
  compileCb: CompileCallback
): bool =
  echo "\n" & ColCyan & ColBold & "======================================================================" & ColReset
  echo ColCyan & ColBold & "🐘 Pgxcrown Test Runner [PostgreSQL " & $pgVersion & " — local engine]" & ColReset
  echo ColCyan & ColBold & "======================================================================" & ColReset

  let testCases = discoverTests(projectDir)
  if testCases.len == 0:
    echo "ℹ️  No test files found in " & (projectDir / "tests" / "sql") & "."
    return true

  if compileCb != nil:
    let entryPoint = projectDir / "src" / "main.nim"
    if fileExists(entryPoint):
      echo "📦 [1/3] Compiling extension natively for local PostgreSQL " & $pgVersion & "..."
      compileCb(entryPoint, pgVersion)

  if not installProjectLocally(projectDir, project):
    return false

  let testDb = "pgxtool_test_" & project
  echo "🗄️  [2/3] Creating clean database '" & testDb & "' and loading " & (if isHook: "hook" else: "extension") & "..."
  discard execCmdEx("psql -U postgres -d postgres -c \"DROP DATABASE IF EXISTS \\\"" & testDb & "\\\" WITH (FORCE);\"")
  let (createOut, createCode) = execCmdEx("psql -U postgres -d postgres -c \"CREATE DATABASE \\\"" & testDb & "\\\";\"")
  if createCode != 0:
    echo ColRed & "❌ Failed to create database '" & testDb & "': " & createOut & ColReset
    return false
  if isHook:
    let escapedHook = project.replace("'", "''")
    # Execute ALTER SYSTEM and pg_reload_conf in separate -c calls; psql wraps multi-statement -c in a transaction block.
    let alterSql = "ALTER SYSTEM SET session_preload_libraries = '" & escapedHook & "';"
    let (hookOut, hookCode) = execCmdEx("psql -U postgres -d postgres -c " & quoteShell(alterSql))
    if hookCode != 0:
      echo ColRed & "❌ Failed to configure session_preload_libraries for hook '" & project & "': " & hookOut & ColReset
      return false
    let (reloadOut, reloadCode) = execCmdEx("psql -U postgres -d postgres -c \"SELECT pg_reload_conf();\"")
    if reloadCode != 0:
      echo ColRed & "❌ Failed to reload PostgreSQL configuration for hook '" & project & "': " & reloadOut & ColReset
      return false
    let (verifyOut, verifyCode) = execCmdEx("psql -U postgres -d " & quoteShell(testDb) & " -c \"LOAD '" & escapedHook & "';\"")
    if verifyCode != 0:
      echo ColRed & "❌ Failed to load hook '" & project & "': " & verifyOut & ColReset
      return false
  else:
    let (extOut, extCode) = execCmdEx("psql -U postgres -d " & quoteShell(testDb) & " -c \"CREATE EXTENSION \\\"" & project & "\\\" CASCADE;\"")
    if extCode != 0:
      echo ColRed & "❌ Failed to run 'CREATE EXTENSION " & project & "': " & extOut & ColReset
      return false

  echo "🧪 [3/3] Executing SQL regression tests..."
  return executeAndVerifyTestCases(
    testCases = testCases,
    bless = bless,
    verbose = verbose,
    pgVersion = pgVersion,
    execSql = proc(sqlPath: string): (string, int) =
      let localSqlPath = "/tmp/current_test.sql"
      copyFile(sqlPath, localSqlPath)
      try:
        execCmdEx("psql -U postgres -d " & quoteShell(testDb) & " -X -a -P pager=off -v ON_ERROR_STOP=0 -f " & quoteShell(localSqlPath))
      finally:
        if fileExists(localSqlPath):
          removeFile(localSqlPath)
  )

proc serveTestEnv*(
  pgxtool_init_dir: string,
  pgxtool_config: string,
  project: string,
  pgVersionStr: string = "",
  bless: bool = false,
  allVersions: bool = false,
  keepContainer: bool = false,
  verbose: bool = false,
  compileCb: CompileCallback = nil,
  projectDirOverride: string = "",
  isHook: bool = false,
  debug: bool = false,
  localMode: bool = false
): int =
  let projectDir = if projectDirOverride.len > 0: projectDirOverride else: pgxtool_init_dir / project
  if not dirExists(projectDir):
    quit("❌ Project directory not found: " & projectDir)

  ensureTestDirectories(projectDir)

  var docker: DockerDriver
  let useLocal = localMode or (not tryDetectDockerEngine(docker) and isInsideContainer())

  if useLocal:
    let hostVer = detectHostPgVersion()
    if allVersions:
      quit("❌ '--all' requires Docker from the host. Inside this container only PostgreSQL " & $hostVer & " is installed (omit '--all' or run without '--local' from the host).")
    if pgVersionStr.len > 0:
      let reqVer = parsePgVersion(pgVersionStr)
      if reqVer == -1:
        quit("❌ Unsupported PostgreSQL version: '" & pgVersionStr & "'. Supported versions: " & $SupportedPgVersions)
      if reqVer != hostVer:
        quit("❌ Local container PostgreSQL is " & $hostVer & ", cannot test '--pg " & $reqVer & "' locally. Run from the host with Docker for multi-version testing.")
    let passed = runLocalTestSuite(project, projectDir, hostVer, bless, verbose, isHook, compileCb)
    return if passed: 0 else: 1

  if not tryDetectDockerEngine(docker):
    discard detectDockerEngine() # prints consistent Docker error & exits

  echo "🔍 Container Engine: " & ColBold & "Docker" & ColReset & " (" & docker.binaryPath & ", image repo: " & getPgxcrownImageRepo() & ")"

  var targetVersions: seq[int] = @[]
  if allVersions:
    for v in SupportedPgVersions:
      targetVersions.add v
  elif pgVersionStr.len > 0:
    for part in pgVersionStr.split(','):
      let cleanPart = part.strip()
      if cleanPart.len == 0: continue
      let v = parsePgVersion(cleanPart)
      if v == -1:
        quit("❌ Unsupported PostgreSQL version: '" & cleanPart & "'. Supported versions: " & $SupportedPgVersions)
      if v notin targetVersions:
        targetVersions.add v
    if targetVersions.len == 0:
      quit("❌ Empty '--pg' version argument.")
  else:
    targetVersions.add detectHostPgVersion()

  var allPassed = true
  var versionResults: seq[(int, bool)] = @[]

  for ver in targetVersions:
    let passed = runTestSuiteForVersion(
      project = project,
      projectDir = projectDir,
      docker = docker,
      pgVersion = ver,
      bless = bless,
      keepContainer = keepContainer,
      verbose = verbose,
      isHook = isHook,
      debug = debug,
      compileCb = compileCb
    )
    versionResults.add (ver, passed)
    if not passed:
      allPassed = false

  if targetVersions.len > 1:
    echo "\n" & ColBold & "================== MULTI-VERSION TEST MATRIX ==================" & ColReset
    for (ver, passed) in versionResults:
      let statusStr = if passed: ColGreen & "✅ PASSED" & ColReset else: ColRed & "❌ FAILED" & ColReset
      echo "  • PostgreSQL " & align($ver, 2) & ": " & statusStr
    echo ColBold & "================================================================" & ColReset

  return if allPassed: 0 else: 1
