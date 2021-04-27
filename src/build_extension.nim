from strutils import parseInt, repeat, join, split
from osproc import execCmd, execCmdEx
import tables,os

var file = paramStr(1)

discard execCmd "nim c -d:release --hints:off --opt:size --app:lib " & file & ".nim"

var produced_lib = "lib"&extractFilename(file)

var postgreslib = execCmdEx("pg_config --pkglibdir").output.split("\n")[0]

echo "Moving ",produced_lib,".so to ", postgreslib
discard execCmd "sudo mv "&produced_lib&".so "&postgreslib

var nim_target_function:string 

proc build_pg_function():string = 

    nim_target_function = execCmdEx("""grep -i pgv1 """ & file & """.nim | awk '{ print $2}' | tr "()" "\n" | head -n1""").output.split("\n")[0]

    var create_function = "CREATE OR REPLACE FUNCTION "&nim_target_function&"_funtion_template"

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

    result = create_function & param_builder & returns & " as '"&file&".so' , '"&nim_target_function&"' LANGUAGE C STRICT;"

discard execCmd """ echo " """ & build_pg_function() & """ " > """ & nim_target_function & ".sql"

echo "Created file: ",nim_target_function,".sql"

