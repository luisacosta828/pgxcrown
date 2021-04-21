from strutils import parseInt, repeat, join

import tables

var file = paramStr(2)

exec "nim c -d:release --hints:off --opt:size --app:lib "&file

var postgreslib = gorgeEx "pg_config --pkglibdir"

exec "sudo cp "&file.toDll& " "&postgreslib.output

var nim_target_function:string 

proc build_pg_function():string = 

    nim_target_function = gorgeEx("""grep -i pgv1 sclera_extension.nim | awk '{ print $2}' | tr "()" "\n" | head -n1""").output

    var create_function = "CREATE OR REPLACE FUNCTION "&nim_target_function&"_funtion_template"

    var types = {"Int16": "int", "Int32": "int", "Float4":"real", "Float8": "real", "Varchar": "varchar"}.toTable

    var get_type:tuple[output:string, exitCode:int]
    var return_type:tuple[output:string, exitCode:int]
    var total_args:int
    var param_builder:string = "("
    var returns:string
    var args:seq[string]

    for key,value in types.pairs():

        get_type = gorgeEx("grep -c get"&key&" "&file&".nim")
        return_type = gorgeEx("grep -c return"&key&" "&file&".nim")

        if get_type.exitCode == 0:
           total_args = parseInt(get_type.output) - 1
           for i in 0..total_args:
               args.add(value)
        if return_type.exitCode == 0:
           returns = " RETURNS "&value
    param_builder = param_builder & args.join(",") & ")"
    result = create_function & param_builder & returns & " as '"&file.toDll&"' , '"&nim_target_function&"' LANGUAGE C STRICT;"
    
exec """ echo " """ & build_pg_function() & """ " > """ & nim_target_function & ".sql"

echo "Created file: "& nim_target_function & ".sql"

