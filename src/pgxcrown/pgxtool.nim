from strutils import parseInt, repeat, join, split
from osproc import execCmd, execCmdEx
import tables,os

var nim_target_function* :string 

{.push inline .}

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

proc cli_helper() =
   echo """
Usage: pgxtool --build-extension [filename]
Hint: filename without .nim extension
"""

{.pop.}

if paramCount() > 1:
   var buildopt = paramStr(1)
   var filename = paramStr(2)

   if buildopt == "--build-extension":
       discard execCmdEx( """ echo " """& build_pg_function(filename) & """" > """ & nim_target_function & ".sql" )
   else:
       cli_helper()
elif paramCount() == 1: 
     var buildopt = paramStr(1)
     if buildopt == "--build-plnim-function-handler":
        compile_library("~/.nimble/pkgs/pgxcrown-0.4.1/pgxcrown/plnim/plnim")
else:
    cli_helper()
