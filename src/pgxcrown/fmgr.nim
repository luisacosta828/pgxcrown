include compiler

{. push header: "postgres.h" .}

type 
    Datum* {.importc: "Datum".} = cuint

{. pop .}

{. push header: "fmgr.h" .}
   
proc getInt32*(value: cuint): cuint {. importc: "PG_GETARG_INT32" .} 
proc getFloat4*(value: cuint): cfloat {. importc: "PG_GETARG_FLOAT4"  .}
proc getFloat8*(value: cuint): cdouble {. importc: "PG_GETARG_FLOAT8" .}

template returnInt32*(value: typed) = {. emit: ["""PG_RETURN_INT32(""",value, ");" ].}
template returnFloat4*(value: typed) = {. emit: ["""PG_RETURN_FLOAT4(""",value, ");" ].}
template returnFloat8*(value: typed) = {. emit: ["""PG_RETURN_FLOAT8(""",value, ");" ].}

{.pop.}

