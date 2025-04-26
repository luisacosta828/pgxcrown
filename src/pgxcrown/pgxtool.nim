import std/[os, strutils, json]
import pathfinders
import test_suite

const available_hooks = ["emit_log", "post_parse_analyze"]
const platform_compiler: string = when defined(windows):
  "vcc"
elif defined(linux):
  "gcc"
else:
  quit "Unsupported operating system"

const
  home = getHomeDir()
  current_user = home.lastPathPart
  pgxtool_init_dir = home / current_user & "_pgxtool"
  pgxtool_config = pgxtool_init_dir / "config.json"


const available_base_types = ["int", "int32", "int64", "uint", "uint32", "uint64", "char", "string", "cstring","float32", "float64"]

const type_template = """
import std/strutils

type $udf = $base_type

proc $udf_input(a: cstring): $udf =
  discard

proc $udf_output(a: $udf): cstring =
  discard
"""

proc cli_helper() =
  echo """
Usage: pgxtool [command] [options] [target]

Commands:
  init: Initialize working directory
     * pgxtool init

  create-project: Initialize a new pgxcrown project template to edit
     * pgxtool create-project test

  create-type: Create a template for defining new types
     * pgxtool create-type test --base-type nim_datatype

  build-extension: Compile a dynamic library that can be loaded into Postgres (.so in Linux, .dll in Windows)
     * pgxtool build-extension test

  create-hook: Initialize a new project template for creating Postgres hooks
     * pgxtool create-hook emit_log

  available-hooks: List Postgres hooks supported for pgxcrown
     * pgxtool available-hooks

  path-finders: List Postgres pg_config, libdir, includedir paths
     * pgxtool path-finders

  test: Test an extension
     * pgxtool test project

"""
proc wrap(s: string): string {. inline .} = "\"" & s & "\""

proc nim_c(module: string): string {.inline.} =
  "nim c -d:release --cc:" & platform_compiler & " -d:entrypoint=" & wrap(module) & " " & wrap(module)


proc emit_pgx_c_extension(module: string): string {.inline.} =
  var prj = module.splitPath.head
  "nim c -d:release --cc:" & platform_compiler & " --app:lib -o:" & wrap(prj.splitPath.head.splitPath.tail) & " --outdir:" & wrap(prj) & " " & wrap(module)


template generate_tmp_file(input_file: string, kind: string = "") =
  var
    pgxcrown_header = if "hook" in kind: "import pgxcrown/hooks/hook_builder\n\n" else: "import pgxcrown/pgx\n\n"
    original_content = readFile(input_file)
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
    entry_point = source / "main.nim"

  createDir(source)
  createDir(private)
  
  if kind in "create-project":
    writeFile(entry_point, "")
  elif "create-type" in kind:
    writeFile(entry_point, type_template.replace("$udf", req).replace("$base_type", kind.split(":")[^1]))


  if "hook" in kind:
    generate_tmp_file(entry_point, kind)
    writeFile(tmp_file, tmp_content)
    run nim_c(tmp_file)

    #writeFile(source / "hook_type.txt", kind.split(":")[1])

proc compile2pgx(input_file: string) =
  generate_tmp_file input_file
  writeFile(tmp_file, tmp_content)
  run nim_c(tmp_file)
  run emit_pgx_c_extension(tmp_file)

  #clean up project folder
  removeFile(tmp_file)
  var exe = tmp_file.splitFile()
  removeFile(exe.dir / exe.name)


proc compile2hook(input_file: string) =
  run emit_pgx_c_extension(input_file)


template build_project_template(req: string, kind: string = "") =
  if dirExists( pgxtool_init_dir / req):
    echo "Path in use, directory already exists, choose another name."
    return
  build_project(req, kind)

template validate_second_arg(pc: int) =
  if pc != 2:
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
  else:
    cli_helper()
    return


proc check_command(pc: int) =
  var
    arg = paramStr(1)
    req:string

  if arg in ["available-hooks","path-finders","init"] : 
    req = ""    

  case arg
  of "create-hook":
    validate_second_arg(pc)
    req = paramStr(2)
    if req in available_hooks:
      build_project_template(req, "hook:" & req)
    else:
      echo req & " is not supported yet. Check pgxtool available-hooks!"
  of "create-project":
    validate_second_arg(pc)
    req = paramStr(2)
    build_project_template(req, arg)
  of "create-type":
    validate_create_type_args(pc)
    req = paramStr(2)
    build_project_template(req, arg & ":" & base_type)
  of "build-extension":
    validate_second_arg(pc)
    req = paramStr(2)
    var entry_point = pgxtool_init_dir / req / "src" / "main.nim"
    if fileExists(entry_point):
      if req in available_hooks:
        compile2hook(entry_point)
      else:
        compile2pgx(entry_point)
  of "path-finders":
    echo "pg_config  = ", pgconfigFinder()
    echo "includedir = ", pgIncludeFinder()
    echo "libdir     = ", pgLibFinder()
  of "available-hooks":
    echo """
    * emit_log
    * post_parse_analyze
    """
  of "init":
    prepare_working_directory
  of "test":
    validate_second_arg(pc)
    req = paramStr(2)
    serveTestEnv(pgxtool_init_dir, pgxtool_config, req)  

  else: cli_helper()


proc main() =
  let pc = paramCount()
  case pc
  of 1, 2, 4: check_command(pc)
  else: cli_helper()


main()
