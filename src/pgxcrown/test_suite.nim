import std/[os, strutils, times]
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

proc ensureTestDirectories(projectDir: string) =
  let sqlDir = projectDir / "tests" / "sql"
  let expDir = projectDir / "tests" / "expected"
  createDir(sqlDir)
  createDir(expDir)

proc runTestSuiteForVersion*(
  project: string,
  projectDir: string,
  docker: DockerDriver,
  pgVersion: int,
  bless: bool,
  keepContainer: bool,
  verbose: bool = false,
  compileCb: CompileCallback = nil
): bool =
  echo "\n" & ColCyan & ColBold & "======================================================================" & ColReset
  echo ColCyan & ColBold & "🐘 Pgxcrown Test Runner [PostgreSQL " & $pgVersion & " via Docker]" & ColReset
  echo ColCyan & ColBold & "======================================================================" & ColReset

  var testCases = discoverTests(projectDir)
  if testCases.len == 0:
    echo "ℹ️  No test files found in " & (projectDir / "tests" / "sql") & "."
    echo "   Create a .sql script (e.g. tests/sql/01_basic.sql) to test your extension queries."
    return true

  if compileCb != nil:
    let entryPoint = projectDir / "src" / "main.nim"
    if fileExists(entryPoint):
      echo "📦 Compiling extension for PostgreSQL " & $pgVersion & " target ABI..."
      compileCb(entryPoint, pgVersion)

  let containerName = "pgxtool_sandbox_" & project & "_pg" & $pgVersion
  echo "🚀 [1/4] Starting PostgreSQL " & $pgVersion & " sandbox container..."
  let ctx = setupPgSandbox(docker, containerName, pgVersion)

  echo "📦 [2/4] Injecting extension '" & project & "' into PostgreSQL engine..."
  if not ctx.injectExtensionFiles(projectDir, project):
    if not keepContainer: ctx.cleanupSandbox()
    echo ColRed & "❌ Failed to inject extension binaries into container." & ColReset
    return false

  let testDb = "pgxtool_test_" & project
  echo "🗄️  [3/4] Creating clean database '" & testDb & "' and loading extension..."
  if not ctx.createCleanDatabase(testDb, project):
    if not keepContainer: ctx.cleanupSandbox()
    echo ColRed & "❌ Failed to create clean test database and load extension." & ColReset
    return false

  echo "🧪 [4/4] Executing SQL regression tests..."

  var passedCount = 0
  var failedCount = 0
  var blessedCount = 0

  for tc in testCases:
    let startTime = epochTime()
    let (actualOutput, _) = ctx.executeSqlInContainer(testDb, tc.sqlPath)
    let elapsedMs = int((epochTime() - startTime) * 1000)

    if bless or not fileExists(tc.expectedPath):
      blessExpectedFile(tc.expectedPath, actualOutput)
      echo "   • tests/sql/" & tc.name & ".sql ...... " & ColYellow & "✨ BLESSED" & ColReset & " (" & $elapsedMs & "ms)"
      if verbose:
        echo ColDim & "     ┌─ [PostgreSQL Response] ──────────────────────────────────" & ColReset
        for line in actualOutput.strip.splitLines():
          echo ColDim & "     │ " & ColReset & line
        echo ColDim & "     └─────────────────────────────────────────────────────────" & ColReset
      inc blessedCount
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

  if not keepContainer:
    echo "🧹 Cleaning up sandbox container..."
    ctx.cleanupSandbox()
  else:
    echo "ℹ️  Container '" & containerName & "' kept alive for debugging."
    echo "   Connect via: " & docker.binaryPath & " exec -it " & containerName & " psql -U postgres -d " & testDb

  echo "----------------------------------------------------------------------"
  if failedCount == 0:
    echo ColGreen & ColBold & "🎉 PG " & $pgVersion & " ALL TESTS PASSED (" & $passedCount & "/" & $testCases.len & ")" & ColReset
    return true
  else:
    echo ColRed & ColBold & "❌ PG " & $pgVersion & " FAILURES: " & $failedCount & " failed, " & $passedCount & " passed" & ColReset
    return false

proc serveTestEnv*(
  pgxtool_init_dir: string,
  pgxtool_config: string,
  project: string,
  pgVersionStr: string = "",
  bless: bool = false,
  allVersions: bool = false,
  keepContainer: bool = false,
  verbose: bool = false,
  compileCb: CompileCallback = nil
): int =
  let projectDir = pgxtool_init_dir / project
  if not dirExists(projectDir):
    quit("❌ Project directory not found: " & projectDir)

  let docker = detectDockerEngine()
  echo "🔍 Container Engine: " & ColBold & "Docker" & ColReset & " (" & docker.binaryPath & ")"

  ensureTestDirectories(projectDir)

  var targetVersions: seq[int] = @[]
  if allVersions:
    for v in SupportedPgVersions:
      targetVersions.add v
  elif pgVersionStr.len > 0:
    let v = parsePgVersion(pgVersionStr)
    if v == -1:
      quit("❌ Unsupported PostgreSQL version: '" & pgVersionStr & "'. Supported versions: " & $SupportedPgVersions)
    targetVersions.add v
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
