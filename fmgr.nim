include compiler

{. push header: "utils.h" .}

type 
    Datum* {.importc: "Datum".} = cuint

template PG_MODULE_MAGIC* =     
    const DLL = "PGDLLEXPORT $# $#$#"
    const V1_DEF = "PGDLLEXPORT $# $#(PG_FUNCTION_ARGS)"
    {.pragma: pgdllexport, codegenDecl: DLL, exportc.}
    {.pragma: pgv1 , codegenDecl: V1_DEF, exportc, dynlib.}

template PG_FUNCTION_INFO_V1*(funcname: typed) = 
    {.emit: ["""PG_FUNCTION_INFO_V1(""",funcname.astToStr,");"] .}
    
proc getInt32*(value: cuint): cuint {. importc: "PG_GETARG_INT32" .} 
proc getFloat4*(value: cuint): cfloat {. importc: "PG_GETARG_FLOAT4"  .}
proc getFloat8*(value: cuint): cdouble {. importc: "PG_GETARG_FLOAT8" .}

template returnInt32*(value: typed) = {. emit: ["""PG_RETURN_INT32(""",value, ");" ].}
template returnFloat4*(value: typed) = {. emit: ["""PG_RETURN_FLOAT4(""",value, ");" ].}
template returnFloat8*(value: typed) = {. emit: ["""PG_RETURN_FLOAT8(""",value, ");" ].}

{.pop.}