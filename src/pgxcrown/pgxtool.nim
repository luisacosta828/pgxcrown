import std/[os, strutils, json, osproc]
import pathfinders
import test_suite

const available_hooks = ["emit_log", "post_parse_analyze"]
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

const
  home = getHomeDir()
  current_user = home.lastPathPart
  pgxtool_init_dir = home / current_user & "_pgxtool"
  pgxtool_config = pgxtool_init_dir / "config.json"

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

  let src = "import pgxcrown\nimport std/strutils\n\ntype\n  " & udf & "* {.pgxType: " & baseType & ".} = distinct " & baseType & "\n\nproc parse_" & udf & "*(s: cstring): " & udf & " {.pgxInput, immutable, parallelSafe.} =\n  " & parseCode & "\n\nproc format_" & udf & "*(val: " & udf & "): string {.pgxOutput, immutable, parallelSafe.} =\n  $val." & baseType & "\n"
  let testSql = "SELECT " & testLiteral & "::" & udf & ";\n"
  return (src, testSql)

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

  build-extension: Compile a dynamic library that can be loaded into Postgres (.so in Linux, .dll in Windows)
     * pgxtool build-extension <name>

  install: Automatically copy built extension files (.so, .control, .sql) to PostgreSQL directories
     * pgxtool install <name>

  create-hook: Initialize a new project template for creating Postgres hooks
     * pgxtool create-hook emit_log

  available-hooks: List Postgres hooks supported for pgxcrown
     * pgxtool available-hooks

  path-finders: List Postgres pg_config, libdir, includedir paths
     * pgxtool path-finders

  test: Run regression tests in isolated Docker containers (PostgreSQL 14 to 17)
     * pgxtool test <name>
     * pgxtool test <name> --verbose
     * pgxtool test <name> --pg 16
     * pgxtool test <name> --all
     * pgxtool test <name> --bless
     * pgxtool test <name> --keep
     * pgxtool test --help

"""

proc test_cli_helper() =
  echo """
Usage: pgxtool test <project> [options]

Run SQL regression tests in isolated Docker containers (PostgreSQL 14 to 17).

Arguments:
  <project>               Name of the extension project to test

Options:
  --verbose, -v           Display the full SQL script and raw PostgreSQL query response table
  --pg <version>          Specify target PostgreSQL version (14, 15, 16, 17, or 'latest')
                          Defaults to host PostgreSQL version (if detected) or 17
  --all, --all-versions   Execute test suite across the full matrix of supported PostgreSQL versions (14 to 17)
  --bless                 Auto-generate or update golden snapshot files (tests/expected/*.out) from actual output
  --keep                  Keep the test sandbox container alive after running tests for manual debugging
  --help, -h              Display this help message

Examples:
  * pgxtool test my_ext
  * pgxtool test my_ext --verbose
  * pgxtool test my_ext --pg 16
  * pgxtool test my_ext --all
  * pgxtool test my_ext --bless
  * pgxtool test my_ext --keep
"""

proc wrap(s: string): string {. inline .} = "\"" & s & "\""

proc getPgxcrownPath(): string {.inline.} =
  let repoSrc = currentSourcePath.parentDir.parentDir
  if dirExists(repoSrc / "pgxcrown"):
    " --path:" & wrap(repoSrc) & " "
  else:
    " "

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

proc nim_c*(module: string, targetPgVersion: int = 0): string {.inline.} =
  var extraDefines = ""
  if targetPgVersion > 0:
    extraDefines = " -d:pgTargetVersion=" & $targetPgVersion
  "nim c --noMain --compileOnly -d:release --mm:orc --cc:" & getPlatformCompiler() & getPgxcrownPath() & getCIncludes() & extraDefines & " -d:entrypoint=" & wrap(module) & " " & wrap(module)

proc emit_pgx_c_extension*(module: string, targetPgVersion: int = 0): string {.inline.} =
  var prj = module.splitPath.head
  var extraDefines = ""
  if targetPgVersion > 0:
    extraDefines = " -d:pgTargetVersion=" & $targetPgVersion
  "nim c -d:release --mm:orc --cc:" & getPlatformCompiler() & getPgxcrownPath() & getCIncludes() & getCLibs() & extraDefines & " -d:entrypoint=" & wrap(module) & " --app:lib -o:" & wrap(prj.splitPath.head.splitPath.tail) & " --outdir:" & wrap(prj) & " " & wrap(module)

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
    writeFile(entry_point, "")
  elif "create-type" in kind:
    let baseType = kind.split(":")[^1]
    let (srcCode, testSql) = generateTypeSource(req, baseType)
    writeFile(entry_point, srcCode)
    writeFile(testsSql / "01_basic.sql", testSql)

  if "hook" in kind:
    generate_tmp_file(entry_point, kind)
    writeFile(tmp_file, tmp_content)
    run nim_c(tmp_file)

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

  let (output, exitCode) = osproc.execCmdEx("nm -D " & quoteShell(soPath))
  if exitCode == 0:
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
  let filesToDelete = [
    tmpFile,
    dir / "tmp_main",
    dir / prjName,
    dir / prjName & ".so",
    dir / "lib" & prjName & ".so",
    dir / prjName & ".control",
    dir / prjName & ".sql",
    dir / prjName & "--0.0.1.sql",
    dir / "install.sh"
  ]
  for f in filesToDelete:
    if fileExists(f):
      removeFile(f)

proc compile2pgx*(input_file: string, targetPgVersion: int = 0) =
  var (dir, file, _) = splitFile(input_file)
  let projectDir = dir.parentDir()
  let prjName = projectDir.splitFile().name

  generate_tmp_file input_file
  writeFile(tmp_file, tmp_content)

  if execShellCmd(nim_c(tmp_file, targetPgVersion)) != 0:
    cleanupGeneratedFiles(dir, prjName, tmp_file)
    quit "Error executing: nim_c"

  if execShellCmd(emit_pgx_c_extension(tmp_file, targetPgVersion)) != 0:
    cleanupGeneratedFiles(dir, prjName, tmp_file)
    quit "Error executing: emit_pgx_c_extension"

  let soFile = dir / prjName & ".so"
  let plainFile = dir / prjName
  var targetLib = if fileExists(soFile): soFile elif fileExists(plainFile): plainFile else: ""
  
  if targetLib.len > 0:
    if not auditBinarySymbols(targetLib):
      cleanupGeneratedFiles(dir, prjName, tmp_file)
      quit("❌ [SECURITY VIOLATION] Compilation aborted for extension '" & prjName & "' due to restricted C system calls.")

  # clean up temporary wrapper file
  if fileExists(tmp_file):
    removeFile(tmp_file)
  var exe = tmp_file.splitFile()
  if fileExists(exe.dir / exe.name):
    removeFile(exe.dir / exe.name)

proc compile2hook*(input_file: string, targetPgVersion: int = 0) =
  run emit_pgx_c_extension(input_file, targetPgVersion)

proc generate_install_script*(req: string): string =
  var prj_dir = pgxtool_init_dir / req / "src"
  var pkglibdir = pgLibFinder()
  var extdir = pgExtensionDirFinder()
  var script_path = prj_dir / "install.sh"

  var script_content = "#!/bin/bash\nset -e\n\n"
  script_content.add "# Auto-generated install script by pgxtool for extension '" & req & "'\n"
  script_content.add "PKGLIBDIR=\"" & pkglibdir & "\"\n"
  script_content.add "EXTDIR=\"" & extdir & "\"\n"
  script_content.add "PRJ_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n\n"
  script_content.add "echo \"Installing extension '" & req & "' into PostgreSQL...\"\n"
  script_content.add "cd \"$PRJ_DIR\"\n\n"
  script_content.add "echo \"  Copying library to $PKGLIBDIR...\"\n"
  script_content.add "if [ -f \"" & req & ".so\" ]; then\n"
  script_content.add "  cp -f \"" & req & ".so\" \"$PKGLIBDIR/\"\n"
  script_content.add "elif [ -f \"" & req & "\" ]; then\n"
  script_content.add "  cp -f \"" & req & "\" \"$PKGLIBDIR/" & req & ".so\"\n"
  script_content.add "elif [ -f \"lib" & req & ".so\" ]; then\n"
  script_content.add "  cp -f \"lib" & req & ".so\" \"$PKGLIBDIR/" & req & ".so\"\n"
  script_content.add "fi\n\n"
  script_content.add "echo \"  Copying control and SQL files to $EXTDIR...\"\n"
  script_content.add "if [ -f \"" & req & ".control\" ]; then\n"
  script_content.add "  cp -f \"" & req & ".control\" \"$EXTDIR/\"\n"
  script_content.add "fi\n"
  script_content.add "if [ -f \"" & req & "--0.0.1.sql\" ]; then\n"
  script_content.add "  cp -f \"" & req & "--0.0.1.sql\" \"$EXTDIR/\"\n"
  script_content.add "fi\n"
  script_content.add "if [ -f \"" & req & ".sql\" ]; then\n"
  script_content.add "  cp -f \"" & req & ".sql\" \"$EXTDIR/\"\n"
  script_content.add "fi\n\n"
  script_content.add "echo \"Extension '" & req & "' installed successfully!\"\n"
  script_content.add "echo \"To enable it in PostgreSQL, run:\"\n"
  script_content.add "echo \"  psql -c \\\"CREATE EXTENSION " & req & ";\\\"\"\n"

  writeFile(script_path, script_content)
  when not defined(windows):
    discard execShellCmd("chmod +x " & quoteShell(script_path))
  result = script_path

proc install_extension(req: string) =
  var prj_dir = pgxtool_init_dir / req / "src"
  var entry_point = prj_dir / "main.nim"
  if not fileExists(prj_dir / (req & ".control")):
    echo "Extension files for '", req, "' not found in ", prj_dir
    echo "Building extension first..."
    if fileExists(entry_point):
      compile2pgx(entry_point)
    else:
      quit("Error: Main file not found at " & entry_point)

  var script_path = generate_install_script(req)
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

template prepare_working_directory =
  if dirExists(pgxtool_init_dir):
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

  if arg in ["available-hooks", "path-finders", "init", "--help", "-h", "help"]: 
    req = ""    

  case arg
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
  of "build-extension":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      cli_helper()
      return
    var entry_point = pgxtool_init_dir / req / "src" / "main.nim"
    if fileExists(entry_point):
      if req in available_hooks:
        compile2hook(entry_point)
      else:
        compile2pgx(entry_point)
        var script_path = generate_install_script(req)
        echo "Build completed for extension: ", req
        echo "Install script generated at: ", script_path
        echo "To install into PostgreSQL, run:"
        echo "  sudo ", script_path

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
    """
  of "init":
    prepare_working_directory
  of "test":
    if pc == 1:
      test_cli_helper()
      return

    req = paramStr(2)
    if req in ["--help", "-h", "help"]:
      test_cli_helper()
      return

    var pgVersionStr = ""
    var bless = false
    var allVersions = false
    var keepContainer = false
    var verbose = false

    var idx = 3
    while idx <= pc:
      let flag = paramStr(idx)
      if flag in ["--help", "-h"]:
        test_cli_helper()
        return
      elif flag in ["--verbose", "-v"]:
        verbose = true
        idx += 1
      elif flag == "--pg" and idx + 1 <= pc:
        pgVersionStr = paramStr(idx + 1)
        idx += 2
      elif flag == "--all" or flag == "--all-versions":
        allVersions = true
        idx += 1
      elif flag == "--bless":
        bless = true
        idx += 1
      elif flag == "--keep":
        keepContainer = true
        idx += 1
      else:
        echo "⚠️  Unknown option: ", flag
        idx += 1

    let isHook = req in available_hooks
    let compileCallback: CompileCallback = proc(entryPoint: string, targetVersion: int) =
      if isHook:
        compile2hook(entryPoint, targetVersion)
      else:
        compile2pgx(entryPoint, targetVersion)

    let exitCode = serveTestEnv(
      pgxtool_init_dir = pgxtool_init_dir,
      pgxtool_config = pgxtool_config,
      project = req,
      pgVersionStr = pgVersionStr,
      bless = bless,
      allVersions = allVersions,
      keepContainer = keepContainer,
      verbose = verbose,
      compileCb = compileCallback
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
