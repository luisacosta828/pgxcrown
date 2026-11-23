import std/[os, strutils, json, osproc, hashes, times, algorithm]
import pathfinders
import test_suite

const
  available_hooks = ["emit_log", "post_parse_analyze", "executor", "process_utility"]
  NimblePackageSpec =
    when compiles(staticRead("../../pgxcrown.nimble")):
      staticRead("../../pgxcrown.nimble")
    elif compiles(staticRead("../pgxcrown.nimble")):
      staticRead("../pgxcrown.nimble")
    else:
      ""

proc extractPackageVersion(spec: string): string {.compileTime.} =
  for line in spec.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("version") and '=' in trimmed:
      let parts = trimmed.split('=', maxsplit = 1)
      if parts.len == 2:
        return parts[1].strip().strip(chars = {'"', '\''})
  return "unknown"

const PgxcrownVersion* = extractPackageVersion(NimblePackageSpec)
proc getPlatformCompiler(): string {.inline.} =
  when defined(windows):
    if findExe("cl.exe").len > 0 or findExe("cl").len > 0:
      "vcc"
    else:
      "gcc"
  elif defined(linux):
    "gcc"
  else:
    "gcc"

proc getPgxtoolInitDir*(): string =
  let custom = getEnv("PGXTOOL_HOME", "")
  if custom.len > 0: return custom
  let h = getHomeDir()
  let u = h.lastPathPart
  h / (if u.len > 0: u else: "user") & "_pgxtool"

proc getPgxtoolConfig*(): string =
  getPgxtoolInitDir() / "config.json"

var
  home* = getHomeDir()
  current_user* = home.lastPathPart
  pgxtool_init_dir* = getPgxtoolInitDir()
  pgxtool_config* = getPgxtoolConfig()

const available_base_types* = [
  "int", "int16", "int32", "int64",
  "uint", "uint16", "uint32", "uint64",
  "float", "float32", "float64",
  "char", "string", "cstring",
  "bool"
]

proc generateTypeSource*(udf: string, baseType: string): (string, string) =
  var parseCode = ""
  var testLiteral = "'42'"

  case baseType
  of "float", "float32", "float64":
    parseCode = "parseFloat($s)." & baseType & "." & udf
    testLiteral = "'3.14'"
  of "string", "cstring":
    parseCode = "($s)." & udf
    testLiteral = "'hello'"
  of "char":
    parseCode = "($s)[0]." & udf
    testLiteral = "'A'"
  of "bool":
    parseCode = "parseBool($s)." & udf
    testLiteral = "'true'"
  of "int64":
    parseCode = "parseBiggestInt($s)." & udf
    testLiteral = "'42'"
  of "uint64":
    parseCode = "parseBiggestUInt($s)." & udf
    testLiteral = "'42'"
  of "uint", "uint32", "uint16", "uint8":
    parseCode = "parseUInt($s)." & baseType & "." & udf
    testLiteral = "'42'"
  else: # int, int32, int16, int8
    parseCode = "parseInt($s)." & baseType & "." & udf
    testLiteral = "'42'"

  let imports =
    if baseType in ["string", "cstring", "char"]:
      "import pgxcrown\n\n"
    else:
      "import pgxcrown\nimport std/strutils\n\n"
  let src = imports & "type\n  " & udf & "* {.pgxType: " & baseType & ".} = distinct " & baseType & "\n\nproc parse_" & udf & "*(s: cstring): " & udf & " {.pgxInput, immutable, parallelSafe.} =\n  " & parseCode & "\n\nproc format_" & udf & "*(val: " & udf & "): string {.pgxOutput, immutable, parallelSafe.} =\n  $val." & baseType & "\n"
  let testSql = "SELECT " & testLiteral & "::" & udf & ";\n"
  return (src, testSql)

proc generateWorkerSource*(name: string): (string, string) =
  let src = "import pgxcrown\n\n" &
    "# Background Worker entrypoint (pure Nim, zero Datum leaks)\n" &
    "proc " & name & "_worker*() {.pgxWorker.} =\n" &
    "  workerInit(\"postgres\")\n" &
    "  runWorkerLoop(intervalMs = 5000):\n" &
    "    workerActivity(\"Processing worker cycle\"):\n" &
    "      workerTransaction:\n" &
    "        pgNotice(\"Hello from background worker '" & name & "'!\")\n\n" &
    "# SQL launcher function to dynamically start the worker\n" &
    "proc start_" & name & "_worker*(): int32 {.volatile.} =\n" &
    "  let cfg = bgWorker(\"" & name & "\"):\n" &
    "    database \"postgres\"\n" &
    "    restart 30\n" &
    "  let handle = registerDynamicWorker(cfg)\n" &
    "  if handle.isSome:\n" &
    "    let (status, pid) = handle.get.waitForStartup()\n" &
    "    if status == bgwStarted:\n" &
    "      trackWorkerStarted(\"" & name & "\", pid)\n" &
    "      return pid.int32\n" &
    "  return -1'i32\n\n" &
    "# SQL function to gracefully stop the worker\n" &
    "proc stop_" & name & "_worker*(): bool {.volatile.} =\n" &
    "  return stopWorkerByName(\"" & name & "\")\n\n" &
    "# SQL function to query current worker status\n" &
    "proc " & name & "_worker_status*(): string {.volatile.} =\n" &
    "  return getWorkerStatusByName(\"" & name & "\")\n"
  let testSql = "SELECT start_" & name & "_worker() > 0 AS worker_started;\n" &
                "SELECT " & name & "_worker_status();\n" &
                "SELECT stop_" & name & "_worker();\n"
  return (src, testSql)

proc generateProjectSource*(name: string): (string, string) =
  let src = "import pgxcrown\n\n" &
    "# Starter PostgreSQL scalar UDF powered by zero-copy PgText\n" &
    "proc hello_" & name & "*(target: string = \"World\"): string {.immutable, parallelSafe.} =\n" &
    "  return \"Hello, \" & target & \" from pgxcrown!\"\n"
  let testSql = "SELECT hello_" & name & "() AS default_greeting;\n" &
                "SELECT hello_" & name & "('PostgreSQL') AS custom_greeting;\n"
  return (src, testSql)

proc generateHookSource*(hookName: string): (string, string) =
  let src =
    case hookName
    of "emit_log":
      "import pgxcrown\n" &
      "import pgxcrown/hooks/emit_hook\n\n" &
      "PG_MODULE_MAGIC\n" &
      "ActivateHooks\n\n" &
      "var\n" &
      "  emit_log_hook {.original_hook.}: emit_log_hook_type\n" &
      "  prev_emit_log {.user_hook.}: emit_log_hook_type\n\n" &
      "proc custom_proc(edata: ptr ErrorData) {.cdecl.} =\n" &
      "  if prev_emit_log != nil:\n" &
      "    prev_emit_log(edata)\n\n" &
      "proc pg_init() {.exportc: \"_PG_init\", pginitexport.} =\n" &
      "  prev_emit_log = emit_log_hook\n" &
      "  emit_log_hook = custom_proc\n\n" &
      "proc pg_fini() {.exportc: \"_PG_fini\".} =\n" &
      "  emit_log_hook = prev_emit_log\n"
    of "post_parse_analyze":
      "import pgxcrown\n" &
      "import pgxcrown/hooks/post_parse_hook\n\n" &
      "PG_MODULE_MAGIC\n" &
      "ActivateHooks\n\n" &
      "var\n" &
      "  post_parse_analyze_hook {.original_hook.}: post_parse_analyze_hook_type\n" &
      "  prev_post_parse_analyze {.user_hook.}: post_parse_analyze_hook_type\n\n" &
      "proc custom_proc(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.} =\n" &
      "  if prev_post_parse_analyze != nil:\n" &
      "    prev_post_parse_analyze(pstate, query, jstate)\n\n" &
      "proc pg_init() {.exportc: \"_PG_init\", pginitexport.} =\n" &
      "  prev_post_parse_analyze = post_parse_analyze_hook\n" &
      "  post_parse_analyze_hook = custom_proc\n\n" &
      "proc pg_fini() {.exportc: \"_PG_fini\".} =\n" &
      "  post_parse_analyze_hook = prev_post_parse_analyze\n"
    of "executor":
      "import pgxcrown\n\n" &
      "PG_MODULE_MAGIC\n" &
      "ActivateHooks\n\n" &
      "proc onExecutorStart(info: ExecutorQueryInfo, eflags: cint) =\n" &
      "  discard\n\n" &
      "proc onExecutorRun(info: ExecutorQueryInfo, direction: ScanDirection, count: uint64, executeOnce: bool) =\n" &
      "  discard\n\n" &
      "proc onExecutorFinish(info: ExecutorQueryInfo) =\n" &
      "  discard\n\n" &
      "proc onExecutorEnd(info: ExecutorQueryInfo) =\n" &
      "  discard\n\n" &
      "proc pg_init() {.exportc: \"_PG_init\", pginitexport.} =\n" &
      "  registerExecutorStartHook(onExecutorStart)\n" &
      "  registerExecutorRunHook(onExecutorRun)\n" &
      "  registerExecutorFinishHook(onExecutorFinish)\n" &
      "  registerExecutorEndHook(onExecutorEnd)\n\n" &
      "proc pg_fini() {.exportc: \"_PG_fini\".} =\n" &
      "  uninstallExecutorHooks()\n"
    of "process_utility":
      "import pgxcrown\n\n" &
      "PG_MODULE_MAGIC\n" &
      "ActivateHooks\n\n" &
      "proc onProcessUtility(info: UtilityStmtInfo) =\n" &
      "  discard\n\n" &
      "proc pg_init() {.exportc: \"_PG_init\", pginitexport.} =\n" &
      "  registerProcessUtilityHook(onProcessUtility)\n\n" &
      "proc pg_fini() {.exportc: \"_PG_fini\".} =\n" &
      "  uninstallProcessUtilityHook()\n"
    else:
      quit("Unsupported hook template: " & hookName)
  let testSql = "SELECT 1 AS hook_loaded;\n"
  return (src, testSql)

proc build_extension_cli_helper() =
  echo """
Usage: pgxtool build-extension <name> [options]

Compile a dynamic library (.so) for local PostgreSQL installation.

Arguments:
  <name>                  Name of the extension to build

Options:
  --force, -f             Force a full rebuild, bypassing incremental cache
  --clean                 Clean previous build artifacts and cache before building
  --verbose, -v           Show detailed compiler commands and build steps
  --debug, -d             Enable pgxDebug compile-time AST and DDL debug output
  --help, -h              Display this help message

Examples:
  * pgxtool build-extension my_ext
  * pgxtool build-extension my_ext --force
  * pgxtool build-extension my_ext --clean
  * pgxtool build-extension my_ext --verbose
  * pgxtool build-extension my_ext --debug
"""

proc cli_helper() =
  echo """
Usage: pgxtool [command] [options] [target]

Commands:
  init: Initialize working directory
     * pgxtool init

  create-project: Initialize a new pgxcrown project template to edit
     * pgxtool create-project <name>

  create-type: Create a template for defining new types
     * pgxtool create-type <name> --base-type nim_datatype

  create-worker: Initialize a new project template for background workers
     * pgxtool create-worker <name>

  build-extension: Compile a dynamic library (.so) for local PostgreSQL installation
     * pgxtool build-extension <name>
     * pgxtool build-extension <name> --force
     * pgxtool build-extension <name> --clean
     * pgxtool build-extension <name> --verbose
     * pgxtool build-extension <name> --debug

  clean: Remove build cache (.pgx_build) and generated extension artifacts
     * pgxtool clean <name>

  install: Automatically copy built extension files (.so, .control, .sql) to PostgreSQL directories
     * pgxtool install <name>

  create-hook: Initialize a new project template for creating Postgres hooks
     * pgxtool create-hook emit_log

  available-hooks: List Postgres hooks supported for pgxcrown
     * pgxtool available-hooks

  path-finders: List Postgres pg_config, libdir, includedir paths
     * pgxtool path-finders

  test: Run SQL regression tests inside pgxcrown Docker containers (PostgreSQL 14 to 18)
     * pgxtool test <name|path>
     * pgxtool test --pg 16
     * pgxtool test <name> --verbose
     * pgxtool test <name> --debug
     * pgxtool test <name> --pg 16
     * pgxtool test <name> --all
     * pgxtool test <name> --bless
     * pgxtool test <name> --keep
     * pgxtool test <name> --local
     * pgxtool test <name> --preload
     * pgxtool test --help

  version: Show installed pgxcrown / pgxtool version
     * pgxtool --version
"""

proc test_cli_helper() =
  echo """
Usage: pgxtool test [project|path] [options]

Copy a project/test directory into a pgxcrown Docker container (pgxcrown:<version>),
compile and install natively against PostgreSQL <version> headers, and run SQL tests.

Arguments:
  [project|path]          Extension project name (in PGXTOOL_HOME) or directory path.
                          Omit when running inside a project directory (with src/main.nim or tests/sql).

Options:
  --verbose, -v           Display build logs, full SQL script, and raw PostgreSQL responses
  --debug, -d             Enable pgxDebug compile-time AST and DDL debug output inside container
  --pg <version>          Target PostgreSQL version (14, 15, 16, 17, 18, or 'latest', or comma list '14,18')
                          Defaults to host PostgreSQL version (if detected) or 18
  --all, --all-versions   Execute test suite across all supported PostgreSQL versions (14 to 18)
  --bless                 Auto-generate or update golden snapshot files (tests/expected/*.out) from actual output
  --keep                  Keep the test sandbox container alive after running tests for manual debugging
  --local                 Run natively against local PostgreSQL (auto-used inside a container)
  --preload               Load via shared_preload_libraries and restart PostgreSQL (also auto-enabled via tests/preload)
  --help, -h              Display this help message

Examples:
  * pgxtool test my_ext --pg 16
  * pgxtool test ./my_ext --pg 18 --bless
  * pgxtool test --pg 14          (from inside project directory)
  * pgxtool test my_ext --all
  * pgxtool test my_ext --keep -v
"""

proc wrap(s: string): string {. inline .} = "\"" & s & "\""

proc getPgxcrownPath(): string {.inline.} =
  let repoSrc = currentSourcePath.parentDir.parentDir
  if dirExists(repoSrc / "pgxcrown"):
    return " --path:" & wrap(repoSrc) & " "
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
    if dirExists(pkgRoot / "pgxcrown") and fileExists(pkgRoot / "pgxcrown.nim"):
      return " --path:" & wrap(pkgRoot) & " "
  return " "

proc getCIncludes(): string {.inline.} =
  let incServer = pgIncludeServerFinder()
  let incBase = pgIncludeFinder()
  var res = ""
  when defined(windows):
    if incServer.len > 0 and dirExists(incServer):
      if dirExists(incServer / "port" / "win32_msvc"):
        res.add " --cincludes:" & wrap(incServer / "port" / "win32_msvc")
      if dirExists(incServer / "port" / "win32"):
        res.add " --cincludes:" & wrap(incServer / "port" / "win32")
      res.add " --cincludes:" & wrap(incServer)
    if incBase.len > 0 and dirExists(incBase):
      res.add " --cincludes:" & wrap(incBase)
  else:
    if incServer.len > 0 and dirExists(incServer):
      res.add " --cincludes:" & wrap(incServer)
    if incBase.len > 0 and dirExists(incBase):
      res.add " --cincludes:" & wrap(incBase)
  res

proc getCLibs(): string {.inline.} =
  when defined(windows):
    let libd = pgLibFinder()
    if libd.len > 0 and dirExists(libd):
      if fileExists(libd / "postgres.lib"):
        " --clibdir:" & wrap(libd) & " --passL:" & wrap(libd / "postgres.lib") & " "
      else:
        " --clibdir:" & wrap(libd) & " "
    else:
      " "
  else:
    " "

proc nim_c*(module: string, targetPgVersion: int = 0, nimcacheDir: string = "",
            debug: bool = false, projectDir: string = "", realOutDir: string = "",
            extraPaths: seq[string] = @[], entryOverride: string = ""): string {.inline.} =
  var extraDefines = ""
  if targetPgVersion > 0:
    extraDefines.add " -d:pgTargetVersion=" & $targetPgVersion
  if debug:
    extraDefines.add " -d:pgxDebug"
  if projectDir.len > 0:
    extraDefines.add " -d:pgxProjectDir=" & wrap(projectDir)
  if realOutDir.len > 0:
    extraDefines.add " -d:pgxRealOutDir=" & wrap(realOutDir)
  var pathFlags = getPgxcrownPath()
  for p in extraPaths:
    if p.len > 0 and dirExists(p):
      pathFlags.add " --path:" & wrap(p)
  var cacheFlag = ""
  if nimcacheDir.len > 0:
    cacheFlag = " --nimcache:" & wrap(nimcacheDir)
  let ep = if entryOverride.len > 0: entryOverride else: module
  "nim c --noMain --compileOnly -d:release --mm:arc --cc:" & getPlatformCompiler() & pathFlags & getCIncludes() & cacheFlag & extraDefines & " -d:entrypoint=" & wrap(ep) & " " & wrap(module)

proc emit_pgx_c_extension*(module: string, targetPgVersion: int = 0, nimcacheDir: string = "",
                           debug: bool = false, projectDir: string = "", realOutDir: string = "",
                           extraPaths: seq[string] = @[], outDir: string = "", outName: string = ""): string {.inline.} =
  let prj = if outDir.len > 0: outDir else: module.splitPath.head
  let outLibName = if outName.len > 0: outName else: prj.splitPath.head.splitPath.tail
  var extraDefines = ""
  if targetPgVersion > 0:
    extraDefines.add " -d:pgTargetVersion=" & $targetPgVersion
  if debug:
    extraDefines.add " -d:pgxDebug"
  if projectDir.len > 0:
    extraDefines.add " -d:pgxProjectDir=" & wrap(projectDir)
  if realOutDir.len > 0:
    extraDefines.add " -d:pgxRealOutDir=" & wrap(realOutDir)
  when defined(linux):
    extraDefines.add " -d:useMalloc --passC:\"-DPGX_WRAP_MALLOC\" --passL:\"-Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=realloc -Wl,--wrap=free\""
  var pathFlags = getPgxcrownPath()
  for p in extraPaths:
    if p.len > 0 and dirExists(p):
      pathFlags.add " --path:" & wrap(p)
  var cacheFlag = ""
  if nimcacheDir.len > 0:
    cacheFlag = " --nimcache:" & wrap(nimcacheDir)
  "nim c -d:release --mm:arc --cc:" & getPlatformCompiler() & pathFlags & getCIncludes() & getCLibs() & cacheFlag & extraDefines & " -d:entrypoint=" & wrap(module) & " --app:lib -o:" & wrap(outLibName) & " --outdir:" & wrap(prj) & " " & wrap(module)

template generate_tmp_file(input_file: string, kind: string = "") =
  var
    pgxcrown_header = if "hook" in kind: "import pgxcrown/hooks/hook_builder\n\n" else: "import pgxcrown/pgx\n\n"
    original_content = if fileExists(input_file): readFile(input_file) else: ""
    tmp_content {.inject.} = pgxcrown_header & '\n' & original_content
    (dir, file, ext) = splitFile(input_file)
    tmp_file {.inject.} = (dir / ("tmp_" & file & ext))

template run(cmd: string) =
  if execShellCmd(cmd) != 0: quit "Error executing: " & cmd

template build_project(req: string, kind: string) =
  if not fileExists(pgxtool_config):
    quit("Run 'pgxtool init' command first.")
  else:
    var 
      file = parseJson(readFile(pgxtool_config))
      modules = file.getOrDefault("modules")
      project = req.split("pgxtool_init_dir")[^1]
    modules.add(project, %*{"test": {}})
    file["modules"] = modules
    writeFile(pgxtool_config, pretty(file))

  var
    source = pgxtool_init_dir / req / "src"
    private = pgxtool_init_dir / req / "private" 
    testsSql = pgxtool_init_dir / req / "tests" / "sql"
    testsExp = pgxtool_init_dir / req / "tests" / "expected"
    entry_point = source / "main.nim"

  createDir(source)
  createDir(private)
  createDir(testsSql)
  createDir(testsExp)
  
  if "create-project" in kind:
    let (srcCode, testSql) = generateProjectSource(req)
    writeFile(entry_point, srcCode)
    writeFile(testsSql / "01_basic.sql", testSql)
  elif "create-type" in kind:
    let baseType = kind.split(":")[^1]
    let (srcCode, testSql) = generateTypeSource(req, baseType)
    writeFile(entry_point, srcCode)
    writeFile(testsSql / "01_basic.sql", testSql)
  elif "create-worker" in kind:
    let (srcCode, testSql) = generateWorkerSource(req)
    writeFile(entry_point, srcCode)
    writeFile(testsSql / "01_basic.sql", testSql)
  elif "hook" in kind:
    let (srcCode, testSql) = generateHookSource(req)
    writeFile(entry_point, srcCode)
    writeFile(testsSql / "01_basic.sql", testSql)

proc auditBinarySymbols*(soPath: string): bool =
  result = true
  if not fileExists(soPath):
    return true

  # 🚫 STRICTLY BLOCKED OS System Calls (Shell execution, process spawning & file destruction)
  let blockedSymbols = [
    "system", "execve", "execv", "execl", "execlp", "execvp", "execvpe", "fexecve", "popen", "pclose", "fork", "vfork", "clone",
    "unlink", "unlinkat", "remove", "rmdir",
    "chmod", "fchmod", "fchmodat", "chown", "fchown", "lchown", "fchownat", "setuid", "setgid", "seteuid", "setegid"
  ]

  # ℹ️ ALLOWED Dynamic Library Loader Symbols (Used by language handlers like plnim)
  let allowedLoaderSymbols = [
    "dlopen", "dlsym", "dlclose", "dlerror"
  ]

  if findExe("nm") == "":
    echo "❌ [SECURITY AUDIT FAILED] 'nm' utility not found. Please install binutils to run security audits."
    return false

  let (output, exitCode) = osproc.execCmdEx("nm -D " & quoteShell(soPath))
  if exitCode != 0:
    echo "❌ [SECURITY AUDIT FAILED] 'nm' failed to inspect " & soPath & ": " & output.strip()
    return false

  var blockedFlagged: seq[string]
  var loaderFlagged: seq[string]
  for line in output.splitLines():
    if " U " in line:
      let parts = line.splitWhitespace()
      if parts.len > 0:
        let symRaw = parts[^1]
        let symName = symRaw.split('@')[0]
        if symName in blockedSymbols:
          blockedFlagged.add(symRaw)
        elif symName in allowedLoaderSymbols:
          loaderFlagged.add(symRaw)

  if blockedFlagged.len > 0:
    echo "❌ [SECURITY VIOLATION] Restricted OS System Calls Detected in ", soPath, ":"
    for s in blockedFlagged:
      echo "   • Blocked Symbol: '", s, "' (Forbidden by Pgxcrown Security Policy)"
    echo "   Exposing raw shell/OS execution calls compromises PostgreSQL server security."
    return false
  elif loaderFlagged.len > 0:
    echo "ℹ️  [SECURITY AUDIT] Dynamic Library Loader Symbols Detected in ", soPath, ":"
    for s in loaderFlagged:
      echo "   • Extension Loader Symbol: '", s, "'"
    return true
  else:
    echo "🛡️  [SECURITY AUDIT PASSED] No blacklisted OS system calls detected in ", soPath
    return true

proc cleanupGeneratedFiles*(dir: string, prjName: string, tmpFile: string) =
  var filesToDelete = @[
    tmpFile,
    dir / "tmp_main",
    dir / prjName,
    dir / prjName & ".so",
    dir / "lib" & prjName & ".so",
    dir / prjName & ".control",
    dir / prjName & ".sql",
    dir / "install.sh"
  ]
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile:
        let fn = extractFilename(path)
        if fn.startsWith(prjName & "--") and fn.endsWith(".sql"):
          filesToDelete.add(path)
  for f in filesToDelete:
    if fileExists(f):
      removeFile(f)
  let stagedDir = dir.parentDir / ".pgx_build" / "staged_src"
  if dirExists(stagedDir):
    removeDir(stagedDir)
  let manifest = dir.parentDir / ".pgx_build" / "manifest.json"
  if fileExists(manifest):
    removeFile(manifest)

proc collectSortedFilesRec(baseDir: string, onlyNim: bool, skipTmpPrefix: bool): seq[string] =
  result = @[]
  if not dirExists(baseDir):
    return
  for path in walkDirRec(baseDir):
    let fn = extractFilename(path)
    if skipTmpPrefix and fn.startsWith("tmp_"):
      continue
    if onlyNim and not path.endsWith(".nim"):
      continue
    if fileExists(path):
      result.add(path)
  result.sort()

proc stageProjectSources*(projectDir: string, stagedRoot: string): tuple[stagedMain: string, stagedSrc: string, stagedPrivate: string] =
  if dirExists(stagedRoot):
    removeDir(stagedRoot)
  let stagedSrc = stagedRoot / "src"
  let stagedPrivate = stagedRoot / "private"
  createDir(stagedSrc)

  let realSrc = projectDir / "src"
  for srcPath in collectSortedFilesRec(realSrc, onlyNim = true, skipTmpPrefix = true):
    let relPath = srcPath.relativePath(realSrc)
    let destPath = stagedSrc / relPath
    createDir(destPath.parentDir)
    copyFile(srcPath, destPath)

  let realPriv = projectDir / "private"
  if dirExists(realPriv):
    for privPath in collectSortedFilesRec(realPriv, onlyNim = true, skipTmpPrefix = false):
      let relPath = privPath.relativePath(realPriv)
      let destPath = stagedPrivate / relPath
      createDir(destPath.parentDir)
      copyFile(privPath, destPath)

  (
    stagedMain: stagedSrc / "main.nim",
    stagedSrc: stagedSrc,
    stagedPrivate: (if dirExists(stagedPrivate): stagedPrivate else: "")
  )

proc computeSourceHash*(projectDir: string): string =
  var combined = ""
  for f in collectSortedFilesRec(projectDir / "src", onlyNim = true, skipTmpPrefix = true):
    try:
      combined.add(f.relativePath(projectDir) & "\0" & readFile(f) & "\0")
    except CatchableError:
      discard
  for f in collectSortedFilesRec(projectDir / "private", onlyNim = true, skipTmpPrefix = false):
    try:
      combined.add(f.relativePath(projectDir) & "\0" & readFile(f) & "\0")
    except CatchableError:
      discard
  let extJson = projectDir / "pgxext.json"
  if fileExists(extJson):
    try:
      combined.add("pgxext.json\0" & readFile(extJson) & "\0")
    except CatchableError:
      discard
  var nimbleFiles: seq[string] = @[]
  if dirExists(projectDir):
    for kind, path in walkDir(projectDir):
      if kind == pcFile and path.endsWith(".nimble"):
        nimbleFiles.add(path)
  nimbleFiles.sort()
  for nf in nimbleFiles:
    try:
      combined.add(nf.relativePath(projectDir) & "\0" & readFile(nf) & "\0")
    except CatchableError:
      discard
  for mf in collectSortedFilesRec(projectDir / "migrations", onlyNim = false, skipTmpPrefix = false):
    if mf.endsWith(".sql"):
      try:
        combined.add(mf.relativePath(projectDir) & "\0" & readFile(mf) & "\0")
      except CatchableError:
        discard
  result = toHex(hash(combined))

proc ensureProjectGitignore*(projectDir: string) =
  let gitignoreFile = projectDir / ".gitignore"
  var current = if fileExists(gitignoreFile): readFile(gitignoreFile) else: ""
  var modified = false
  for entry in [".pgx_build/", "tmp_*", "*.so", "*.dll"]:
    if entry notin current:
      if current.len > 0 and not current.endsWith("\n"):
        current.add("\n")
      current.add(entry & "\n")
      modified = true
  if modified:
    try:
      writeFile(gitignoreFile, current)
    except CatchableError:
      discard

proc resolveExtProject(pgxtoolInitDir: string, req: string): tuple[name: string, projectDir: string] =
  if req.len == 0:
    let cwd = getCurrentDir().strip(leading = false, trailing = true, chars = {'/', '\\'})
    if fileExists(cwd / "src" / "main.nim"):
      return (cwd.lastPathPart, cwd)
    return ("", "")
  let initCand = pgxtoolInitDir / req
  if dirExists(initCand) and fileExists(initCand / "src" / "main.nim"):
    return (req.strip(leading = false, trailing = true, chars = {'/', '\\'}).lastPathPart, initCand)
  let absCand = absolutePath(req).strip(leading = false, trailing = true, chars = {'/', '\\'})
  if dirExists(absCand) and fileExists(absCand / "src" / "main.nim"):
    return (absCand.lastPathPart, absCand)
  (req.strip(leading = false, trailing = true, chars = {'/', '\\'}).lastPathPart, initCand)

proc clean_extension*(req: string) =
  let (prjName, prjDir) = resolveExtProject(pgxtool_init_dir, req)
  let srcDir = prjDir / "src"
  let buildDir = prjDir / ".pgx_build"
  cleanupGeneratedFiles(srcDir, prjName, srcDir / "tmp_main.nim")
  if dirExists(buildDir):
    removeDir(buildDir)
  echo "🧹 Cleaned build artifacts and cache for extension '", prjName, "'."

proc ensureHostCompileToolchain() =
  if findExe("nim").len == 0:
    quit("❌ 'nim' compiler not found on host PATH.\nℹ️  Tip: run 'pgxtool test <project>' to compile and test inside prebuilt GHCR/Docker containers, or install Nim >= 2.0.0.")
  if findExe(pgconfigFinder()).len == 0 and pgconfigFinder() == "pg_config":
    quit("❌ 'pg_config' not found on host PATH (install PostgreSQL dev headers or run 'pgxtool test <project>' via Docker/GHCR).")

proc compile2pgx*(input_file: string, targetPgVersion: int = 0, force: bool = false, verbose: bool = false, cleanBefore: bool = false, debug: bool = false) =
  ensureHostCompileToolchain()
  let (dir, _, _) = splitFile(input_file)
  let projectDir = dir.parentDir()
  let prjName = projectDir.splitFile().name

  let buildDir = projectDir / ".pgx_build"
  let cacheSubdir = if targetPgVersion > 0: "nimcache_pg" & $targetPgVersion else: "nimcache"
  let nimcacheDir = buildDir / cacheSubdir
  let manifestFile = buildDir / "manifest.json"
  let stagedRoot = buildDir / "staged_src"
  let pass1File = stagedRoot / "pgx_pass1.nim"

  let soFile = dir / prjName & ".so"
  let plainFile = dir / prjName
  var targetLib = if fileExists(soFile): soFile elif fileExists(plainFile): plainFile else: ""

  if cleanBefore:
    cleanupGeneratedFiles(dir, prjName, dir / "tmp_main.nim")
    if dirExists(buildDir):
      removeDir(buildDir)
    targetLib = ""

  ensureProjectGitignore(projectDir)
  createDir(buildDir)
  createDir(nimcacheDir)

  let currentSourceHash = computeSourceHash(projectDir)
  const currentPgxcrownVersion = PgxcrownVersion & "-arc"

  # Smart incremental check: if target library exists and sources haven't changed, skip build (unless debug or force)
  if not force and not cleanBefore and not debug and targetLib.len > 0 and fileExists(targetLib) and fileExists(manifestFile):
    try:
      let manifest = parseJson(readFile(manifestFile))
      let savedHash = manifest.getOrDefault("source_hash").getStr("")
      let savedVer = manifest.getOrDefault("pgxcrown_version").getStr("")
      let savedTargetVer = manifest.getOrDefault("target_pg_version").getInt(0)
      if savedHash == currentSourceHash and savedVer == currentPgxcrownVersion and savedTargetVer == targetPgVersion:
        echo "✨ Extension '", prjName, "' is up to date (no changes detected)."
        echo "   Binary: ", targetLib
        echo "   To force a rebuild, run: pgxtool build-extension ", prjName, " --force"
        return
    except CatchableError:
      discard

  for kind, path in walkDir(dir):
    if kind == pcFile:
      let fn = extractFilename(path)
      if fn.startsWith(prjName & "--") and fn.endsWith(".sql"):
        removeFile(path)

  let (stagedMain, stagedSrc, stagedPrivate) = stageProjectSources(projectDir, stagedRoot)
  writeFile(pass1File, "{.warning[UnusedImport]: off.}\nimport pgxcrown/pgx\n")
  var modulePaths: seq[string] = @[stagedSrc]
  if stagedPrivate.len > 0:
    modulePaths.add(stagedPrivate)

  let cmd1 = nim_c(pass1File, targetPgVersion, nimcacheDir, debug = debug,
                   projectDir = projectDir, realOutDir = dir,
                   extraPaths = modulePaths, entryOverride = stagedMain)
  if verbose or debug:
    echo "  [pgxtool:pass1] ", cmd1
  if execShellCmd(cmd1) != 0:
    cleanupGeneratedFiles(dir, prjName, pass1File)
    if fileExists(manifestFile): removeFile(manifestFile)
    quit "Error executing: nim_c (Pass 1 - DDL & AST generation)"

  let cmd2 = emit_pgx_c_extension(stagedMain, targetPgVersion, nimcacheDir, debug = debug,
                                  projectDir = projectDir, realOutDir = dir,
                                  extraPaths = modulePaths, outDir = dir, outName = prjName)
  if verbose or debug:
    echo "  [pgxtool:pass2] ", cmd2
  if execShellCmd(cmd2) != 0:
    cleanupGeneratedFiles(dir, prjName, pass1File)
    if fileExists(manifestFile): removeFile(manifestFile)
    quit "Error executing: emit_pgx_c_extension (Pass 2 - C compilation & linking)"

  targetLib = if fileExists(soFile): soFile elif fileExists(plainFile): plainFile else: ""

  if targetLib.len > 0:
    if not auditBinarySymbols(targetLib):
      cleanupGeneratedFiles(dir, prjName, pass1File)
      if fileExists(manifestFile): removeFile(manifestFile)
      quit("❌ [SECURITY VIOLATION] Compilation aborted for extension '" & prjName & "' due to restricted C system calls.")

  # Clean up temporary staged source files to leave only built outputs and incremental cache
  if dirExists(stagedRoot):
    removeDir(stagedRoot)

  # Write build manifest for smart incremental caching
  var manifestObj = %*{
    "extension": prjName,
    "source_hash": currentSourceHash,
    "pgxcrown_version": currentPgxcrownVersion,
    "target_pg_version": targetPgVersion,
    "last_build_time": $now(),
    "binary_path": targetLib
  }
  writeFile(manifestFile, pretty(manifestObj))

proc compile2hook*(input_file: string, targetPgVersion: int = 0, verbose: bool = false, debug: bool = false) =
  ensureHostCompileToolchain()
  let (dir, _, _) = splitFile(input_file)
  let projectDir = dir.parentDir()
  let prjName = projectDir.splitFile().name
  let nimcacheDir = projectDir / ".pgx_build" / (if targetPgVersion > 0: "nimcache_pg" & $targetPgVersion else: "nimcache")
  createDir(nimcacheDir)
  let cmd = emit_pgx_c_extension(input_file, targetPgVersion, nimcacheDir, debug = debug,
                                 projectDir = projectDir, realOutDir = dir,
                                 outDir = dir, outName = prjName)
  if verbose or debug:
    echo "  [pgxtool:hook] ", cmd
  run cmd
  let targetLib =
    if fileExists(dir / (prjName & ".so")): dir / (prjName & ".so")
    elif fileExists(dir / prjName): dir / prjName
    else: ""
  if targetLib.len > 0 and not auditBinarySymbols(targetLib):
    removeFile(targetLib)
    quit("❌ [SECURITY VIOLATION] Compilation aborted for hook '" & prjName & "' due to restricted C system calls.")

proc generate_install_script*(req: string, projectDirOverride: string = ""): string =
  let prjName = if projectDirOverride.len > 0: projectDirOverride.splitPath.tail else: req
  let prjDir = if projectDirOverride.len > 0: projectDirOverride / "src" else: pgxtool_init_dir / req / "src"
  var pkglibdir = pgLibFinder()
  var extdir = pgExtensionDirFinder()
  var script_path = prjDir / "install.sh"

  var script_content = "#!/bin/bash\nset -e\n\n"
  script_content.add "# Auto-generated install script by pgxtool for extension '" & prjName & "'\n"
  script_content.add "PKGLIBDIR=\"" & pkglibdir & "\"\n"
  script_content.add "EXTDIR=\"" & extdir & "\"\n"
  script_content.add "PRJ_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n\n"
  script_content.add "echo \"Installing extension '" & prjName & "' into PostgreSQL...\"\n"
  script_content.add "cd \"$PRJ_DIR\"\n\n"
  script_content.add "echo \"  Copying library to $PKGLIBDIR...\"\n"
  script_content.add "if [ -f \"" & prjName & ".so\" ]; then\n"
  script_content.add "  cp -f \"" & prjName & ".so\" \"$PKGLIBDIR/\"\n"
  script_content.add "elif [ -f \"" & prjName & "\" ]; then\n"
  script_content.add "  cp -f \"" & prjName & "\" \"$PKGLIBDIR/" & prjName & ".so\"\n"
  script_content.add "elif [ -f \"lib" & prjName & ".so\" ]; then\n"
  script_content.add "  cp -f \"lib" & prjName & ".so\" \"$PKGLIBDIR/" & prjName & ".so\"\n"
  script_content.add "fi\n\n"
  script_content.add "echo \"  Copying control, schema, and migration SQL files to $EXTDIR...\"\n"
  script_content.add "if [ -d \"../migrations\" ]; then\n"
  script_content.add "  for f in ../migrations/" & prjName & "--*.sql; do\n"
  script_content.add "    [ -f \"$f\" ] && cp -f \"$f\" \"$EXTDIR/\"\n"
  script_content.add "  done\n"
  script_content.add "fi\n"
  script_content.add "if [ -f \"" & prjName & ".control\" ]; then\n"
  script_content.add "  cp -f \"" & prjName & ".control\" \"$EXTDIR/\"\n"
  script_content.add "fi\n"
  script_content.add "for f in " & prjName & "--*.sql; do\n"
  script_content.add "  [ -f \"$f\" ] && cp -f \"$f\" \"$EXTDIR/\"\n"
  script_content.add "done\n"
  script_content.add "if [ -f \"" & prjName & ".sql\" ]; then\n"
  script_content.add "  cp -f \"" & prjName & ".sql\" \"$EXTDIR/\"\n"
  script_content.add "fi\n\n"
  script_content.add "echo \"Extension '" & prjName & "' installed successfully!\"\n"
  script_content.add "echo \"To enable it in PostgreSQL, run:\"\n"
  script_content.add "echo \"  psql -c \\\"CREATE EXTENSION " & prjName & ";\\\"\"\n"

  writeFile(script_path, script_content)
  when not defined(windows):
    discard execShellCmd("chmod +x " & quoteShell(script_path))
  result = script_path

proc install_extension(req: string) =
  let (prjName, prjDirRoot) = resolveExtProject(pgxtool_init_dir, req)
  let prj_dir = prjDirRoot / "src"
  let entry_point = prj_dir / "main.nim"
  if not fileExists(prj_dir / (prjName & ".control")):
    echo "Extension files for '", prjName, "' not found in ", prj_dir
    echo "Building extension first..."
    if fileExists(entry_point):
      compile2pgx(entry_point)
    else:
      quit("Error: Main file not found at " & entry_point)

  var script_path = generate_install_script(prjName, prjDirRoot)
  echo "Generated install script: ", script_path
  echo "To install into PostgreSQL with privileges, run:"
  echo "  sudo ", script_path

template build_project_template(req: string, kind: string = "") =
  if dirExists( pgxtool_init_dir / req):
    echo "Path in use, directory already exists, choose another name."
    return
  build_project(req, kind)

template validate_second_arg(pc: int) =
  if pc < 2:
    cli_helper()
    return

proc resolveTestProject(pgxtoolInitDir: string, req: string): tuple[name: string, dirOverride: string] =
  ## Resolves <name>, <path>, or implicit current directory into project name and directory override.
  if req.len == 0:
    let cwd = getCurrentDir().strip(leading = false, trailing = true, chars = {'/', '\\'})
    if fileExists(cwd / "src" / "main.nim") or dirExists(cwd / "tests" / "sql"):
      return (cwd.lastPathPart, cwd)
    return ("", "")

  let initCandidate = pgxtoolInitDir / req
  if dirExists(initCandidate):
    return (req.strip(leading = false, trailing = true, chars = {'/', '\\'}).lastPathPart, "")

  let absCandidate = absolutePath(req).strip(leading = false, trailing = true, chars = {'/', '\\'})
  let looksLikePathOrProject =
    '/' in req or '\\' in req or req == "." or
    fileExists(absCandidate / "src" / "main.nim") or
    dirExists(absCandidate / "tests" / "sql")
  if dirExists(absCandidate) and looksLikePathOrProject:
    return (absCandidate.lastPathPart, absCandidate)

  return (req, "")

template prepare_working_directory =
  if fileExists(pgxtool_config):
    echo "working directory " & pgxtool_init_dir & " already exists." 
  else:
    echo "Initializing working directory: " & pgxtool_init_dir
    createDir(pgxtool_init_dir)
    var content = %*{"modules":{}}
    writeFile(pgxtool_init_dir / "config.json", $content)

template validate_create_type_args(pc: int) =
  var base_type {.inject.} = "not defined"
  if pc == 4:
    var option = paramStr(3)
    if option != "--base-type":
      cli_helper()
      return
    else:
      base_type = paramStr(4)
      if base_type notin available_base_types:
        quit(base_type & " not supported.\nCheck supported base types:\n" & $available_base_types)
  elif pc == 2:
    base_type = "int"
  else:
    cli_helper()
    return

proc check_command(pc: int) =
  var
    arg = paramStr(1)
    req: string

  if arg in ["available-hooks", "path-finders", "init", "--help", "-h", "help", "--version", "version"]: 
    req = ""    

  case arg
  of "--version", "version":
    echo "pgxtool v", PgxcrownVersion
    return
  of "create-hook":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      cli_helper()
      return
    if req in available_hooks:
      build_project_template(req, "hook:" & req)
    else:
      echo req & " is not supported yet. Check pgxtool available-hooks!"
  of "create-project":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      cli_helper()
      return
    build_project_template(req, arg)
  of "create-type":
    if pc == 2 and paramStr(2) in ["--help", "-h", "help"]:
      echo "Usage: pgxtool create-type <name> --base-type <base_type>\nSupported base types: " & $available_base_types
      return
    validate_create_type_args(pc)
    req = paramStr(2)
    build_project_template(req, arg & ":" & base_type)
  of "create-worker":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      echo "Usage: pgxtool create-worker <name>"
      return
    build_project_template(req, "create-worker")
  of "build-extension":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      build_extension_cli_helper()
      return

    var forceBuild = false
    var cleanBuild = false
    var verboseBuild = false
    var debugBuild = false

    var idx = 3
    while idx <= pc:
      let flag = paramStr(idx)
      if flag in ["--help", "-h"]:
        build_extension_cli_helper()
        return
      elif flag in ["--force", "-f"]:
        forceBuild = true
        idx += 1
      elif flag == "--clean":
        cleanBuild = true
        idx += 1
      elif flag in ["--verbose", "-v"]:
        verboseBuild = true
        idx += 1
      elif flag in ["--debug", "-d"]:
        debugBuild = true
        idx += 1
      else:
        echo "⚠️  Unknown option: ", flag
        idx += 1

    let (resolvedName, resolvedDir) = resolveExtProject(pgxtool_init_dir, req)
    var entry_point = resolvedDir / "src" / "main.nim"
    if fileExists(entry_point):
      let detectedTargetVer = detectHostPgVersion()
      if resolvedName in available_hooks:
        compile2hook(entry_point, targetPgVersion = detectedTargetVer, verbose = verboseBuild, debug = debugBuild)
      else:
        compile2pgx(entry_point, targetPgVersion = detectedTargetVer, force = forceBuild, verbose = verboseBuild, cleanBefore = cleanBuild, debug = debugBuild)
        var script_path = generate_install_script(resolvedName, resolvedDir)
        echo "Build completed for extension: ", resolvedName
        echo "Install script generated at: ", script_path
        echo "To install into PostgreSQL, run:"
        echo "  sudo ", script_path
    else:
      quit("Error: Main file not found at " & entry_point)

  of "clean":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      echo """
Usage: pgxtool clean <name>

Clean build artifacts (.so, .sql, .control, install.sh) and the build cache (.pgx_build) for an extension.
"""
      return
    clean_extension(req)

  of "install":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      cli_helper()
      return
    install_extension(req)

  of "path-finders":
    echo "pg_config  = ", pgconfigFinder()
    echo "includedir = ", pgIncludeFinder()
    echo "libdir     = ", pgLibFinder()
    echo "sharedir   = ", pgShareDirFinder()
    echo "extension  = ", pgExtensionDirFinder()
  of "available-hooks":
    echo """
    * emit_log
    * post_parse_analyze
    * executor
    * process_utility
    """
  of "init":
    prepare_working_directory
  of "test":
    if pc == 1:
      let (implicitName, _) = resolveTestProject(pgxtool_init_dir, "")
      if implicitName.len == 0:
        test_cli_helper()
        return

    var pgVersionStr = ""
    var bless = false
    var allVersions = false
    var keepContainer = false
    var verbose = false
    var debugBuild = false
    var localMode = false
    var preloadMode = false
    req = ""

    var idx = 2
    while idx <= pc:
      let flag = paramStr(idx)
      if flag in ["--help", "-h", "help"]:
        test_cli_helper()
        return
      elif flag in ["--verbose", "-v"]:
        verbose = true
        idx += 1
      elif flag in ["--debug", "-d"]:
        debugBuild = true
        idx += 1
      elif flag == "--pg":
        if idx + 1 > pc:
          quit("❌ Missing PostgreSQL version after '--pg'. Example: pgxtool test my_ext --pg 18")
        pgVersionStr = paramStr(idx + 1)
        idx += 2
      elif flag.startsWith("--pg="):
        pgVersionStr = flag[5..^1]
        idx += 1
      elif flag == "--all" or flag == "--all-versions":
        allVersions = true
        idx += 1
      elif flag == "--bless":
        bless = true
        idx += 1
      elif flag == "--keep":
        keepContainer = true
        idx += 1
      elif flag == "--local":
        localMode = true
        idx += 1
      elif flag == "--preload":
        preloadMode = true
        idx += 1
      elif flag.startsWith("-"):
        echo "⚠️  Unknown option: ", flag
        idx += 1
      elif req.len == 0:
        req = flag
        idx += 1
      else:
        echo "⚠️  Unexpected argument: ", flag
        idx += 1

    let (projectName, projectDirOverride) = resolveTestProject(pgxtool_init_dir, req)
    if projectName.len == 0:
      test_cli_helper()
      return

    let isHook = projectName in available_hooks
    let compileCallback: CompileCallback = proc(entryPoint: string, targetVersion: int) =
      if isHook:
        compile2hook(entryPoint, targetVersion, verbose = verbose, debug = debugBuild)
      else:
        compile2pgx(entryPoint, targetVersion, force = true, verbose = verbose, debug = debugBuild)

    let exitCode = serveTestEnv(
      pgxtool_init_dir = pgxtool_init_dir,
      pgxtool_config = pgxtool_config,
      project = projectName,
      pgVersionStr = pgVersionStr,
      bless = bless,
      allVersions = allVersions,
      keepContainer = keepContainer,
      verbose = verbose,
      compileCb = compileCallback,
      projectDirOverride = projectDirOverride,
      isHook = isHook,
      debug = debugBuild,
      localMode = localMode,
      preload = preloadMode
    )
    if exitCode != 0:
      quit(exitCode)

  else: cli_helper()

proc main() =
  let pc = paramCount()
  if pc >= 1:
    check_command(pc)
  else:
    cli_helper()

if isMainModule:
  main()
