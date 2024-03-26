import std/[os, strutils]

const available_hooks = ["emit_hook", "post_parse_analyze_hook"]

proc cli_helper() =
   echo """
Usage: pgxtool [command] [options] [target]

Commands: 
   create-project: initialize a new pgxcrown project
     * pgxtool create-project test

   build-extension: emits a dynamic library that can be loaded into postgres runtime
     * pgxtool build-extension test

   create-hook: template for creating postgres hooks
     * pgxtool create-hook emit_log

   available-hooks: list hooks supported for pgxcrown
     * pgxtool available-hooks
"""

template nim_c(module: string): string =
  "nim c -d:entrypoint=" & module & " " & module


template emit_pgx_c_extension(module: string): string =
  "nim c --d:release --app:lib " & module

template generate_tmp_file(input_file: string, kind: string = "") =
  var 
    pgxcrown_header               = if "hook" in kind: "import pgxcrown/hooks/hook_builder\n\n" else: "import pgxcrown/pgx\n\n"
    original_content              = readFile(input_file)
    tmp_content {. inject .}      = pgxcrown_header & '\n' & original_content
    (dir, file, ext)              = splitFile(input_file)
    tmp_file {. inject .}         = (dir / ("tmp_" & file & ext))


template build_project(req: string, kind: string) =
  var 
    source      = req / "src"
    entry_point = source / "main.nim"
 
  createDir(req)
  createDir(source)
  writeFile(entry_point, "")

  if "hook" in kind:
    generate_tmp_file(entry_point, kind)
    writeFile(tmp_file, tmp_content)
    discard execShellCmd(nim_c(tmp_file))
    #writeFile(source / "hook_type.txt", kind.split(":")[1])


proc compile2pgx(input_file: string) =
  generate_tmp_file input_file  
  writeFile(tmp_file, tmp_content)
  discard execShellCmd(nim_c(tmp_file))
  discard execShellCmd(emit_pgx_c_extension(tmp_file))
  #removeFile(tmp_file)

proc compile2hook(input_file: string) =
  discard execShellCmd(emit_pgx_c_extension(input_file))

template build_project_template(req: string, kind: string = "") =
  if dirExists(req):
    echo "Path in use, choose another name."
    return
  build_project(req, kind)


proc check_command() =
  var 
    arg = paramStr(1)
    req = if arg == "available-hooks": "" else: paramStr(2)

  case arg:
  of "create-hook":
    if req in available_hooks:
      build_project_template(req, "hook:" & req)
    else:
      echo req & " is not supported yet. Check pgxtool available-hooks!"
  of "create-project":
    build_project_template(req)
  of "build-extension":
    var entry_point = req / "src" / "main.nim"
    if dirExists(req) and fileExists(entry_point):
      if "hook" notin req:
        compile2pgx(entry_point)
      else:
        compile2hook(entry_point)
  of "available-hooks":
    echo """ 
    * emit_hook 
    """
    
#{.pop.}


proc main() =
  let pc = paramCount()

  case pc: 
  of 1, 2: check_command()
  else: cli_helper()

  #[
  if pc == 2:
   var 
     buildopt = paramStr(1)
     filename = paramStr(2)

   if buildopt == "--build-extension":
     echo 1
       #discard execCmdEx( """ echo " """ & build_pg_function(filename) & """" > """ & nim_target_function & ".sql" )
   else:
       cli_helper()
  #elif paramCount() == 1: 
  #   var buildopt = paramStr(1)
  #   if buildopt == "--build-plnim-function-handler":
  #      compile_library("~/.nimble/pkgs/pgxcrown-0.4.1/pgxcrown/plnim/plnim")
  else:
    cli_helper()
    ]#

main()
