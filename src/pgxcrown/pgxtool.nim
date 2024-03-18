import std/os

proc cli_helper() =
   echo """
Usage: pgxtool [command] [options] [target]

Commands: 
   create-project: initialize a new pgxcrown project
     * pgxcrown create-project test

   build-extension: emits a dynamic library that can be loaded into postgres runtime
     * pgxcrown build-extension test

   create-hook: template for creating postgres hooks
     * pgxcrown create-hook emit_log

   available-hooks: list hooks supported for pgxcrown
     * pgxcrown available-hooks
"""

template nim_c(module: string): string =
  "nim c -r -d:entrypoint=" & module & " " & module

template emit_pgx_c_extension(module: string): string =
  "nim c --d:release --app:lib " & module


template build_project(req) =
  var 
    source      = req / "src"
    entry_point = source / "main.nim"
  
  createDir(req)
  createDir(source)
  writeFile(entry_point, "")


proc compile2pgx(input_file: string) =
  var 
    pgxcrown_header  = "import pgxcrown/pgx\n\n"
    original_content = readFile(input_file)
    tmp_content      = pgxcrown_header & '\n' & original_content
    (dir, file, ext) = splitFile(input_file)
    tmp_file         = (dir / ("tmp_" & file & ext))
  
  writeFile(tmp_file, tmp_content)
  discard execShellCmd(nim_c(tmp_file))
  discard execShellCmd(emit_pgx_c_extension(tmp_file))
  #removeFile(tmp_file)

proc check_command() =
  var 
    arg = paramStr(1)
    req = if arg == "available-hooks": "" else: paramStr(2)

  case arg:
  of "create-project":
    if dirExists(req):
      echo "Path in use, choose another name."
      return
    build_project(req)
  of "build-extension":
    var entry_point = req / "src" / "main.nim"

    if dirExists(req) and fileExists(entry_point):
      compile2pgx(entry_point)
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
