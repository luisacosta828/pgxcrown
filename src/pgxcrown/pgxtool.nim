import std/os
#import std/strutils
#from osproc import execCmd, execCmdEx
#import tables,os

#var nim_target_function* :string

#[
proc compile_library(file:string) = echo execCmdEx("nim c -d:release --hints:off --opt:size --app:lib " & file).output
proc getLibName(file:string):string = "lib"&extractFilename(file)
proc getPostgresLibDir(): string = execCmdEx("pg_config --pkglibdir").output.split("\n")[0]

proc moveTo( libname:string, postgreslib:string ) = 
    discard execCmd "sudo mv "&libname&".so "&postgreslib

proc extractV1Function( file:string ):string =
    execCmdEx("""grep -i pgv1 """ & file & """.nim | awk '{ print $2}' | tr "()" "\n" | head -n1""").output.split("\n")[0]

proc createSQLFunction( file:string, nim_target_function: string): string = 
    var create_function = "CREATE OR REPLACE FUNCTION "&nim_target_function&"_template"
    var types = {"Int16": "int", "Int32": "int", "Float4":"real", "Float8": "real", "Varchar": "varchar"}.toTable
    var get_type:tuple[output:string, exitCode:int]
    var return_type:tuple[output:string, exitCode:int]
    var total_args:int
    var param_builder:string = "("
    var returns:string
    var args:seq[string]

    for key,value in types.pairs():
        get_type = execCmdEx("grep -c get"&key&" "&file&".nim")
        return_type = execCmdEx("grep -c return"&key&" "&file&".nim")
        if get_type.exitCode == 0:
           total_args = parseInt(get_type.output.split("\n")[0]) - 1
           for i in 0..total_args:
               args.add(value)
        if return_type.exitCode == 0:
           returns = " RETURNS "&value

    param_builder = param_builder & args.join(",") & ")"
    result = create_function & param_builder & returns & " as '"&getLibName(file)&".so' , '"&nim_target_function&"' LANGUAGE C STRICT;"

proc check_nimcache() {.inline.} = 
    echo "Checking nimcache..."
    var o = execCmdEx(""" [ -d ".cache/nim" ] || $(mkdir .cache; mkdir .cache/nim)  """).output
    echo o

proc build_pg_function*( file:string ):string = 

    check_nimcache()

    echo "Compiling: ",file, "..."
    compile_library(file)
    
    var postgreslib = getPostgresLibDir()
    
    var libname = getLibName(file)

    echo "Moving ",libname,".so to ", postgreslib

    libname.moveTo(postgreslib)    
    nim_target_function = extractV1Function(file)

    echo "Creating SQL Function..."

    result = createSQLFunction(file,nim_target_function)

]#

proc cli_helper() =
   echo """
Usage: pgxtool [command] [options] [target]

Commands: 
   create-project: initialize a new pgxcrown project 
     * pgxcrown create-project test

   build-extension: emits a dynamic library that can be loaded into postgres runtime
     * pgxcrown build-extension test
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
    req = paramStr(2)

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
    


#{.pop.}


proc main() =
  let pc = paramCount()

  case pc:
  of 2: check_command()
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
