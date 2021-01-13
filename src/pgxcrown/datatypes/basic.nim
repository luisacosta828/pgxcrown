# Basic Data Types definitions from postgres.h
{. push header: "postgres.h" .}

type 
    Datum* {.importc: "Datum".} = cuint
    
{. pop .}


# Basic Data Types definitions from fmgr.h

{. push header: "fmgr.h" .}

# Get argument type value declaration
    
proc getInt32*(value: cuint): cint   {. importc: "PG_GETARG_INT32" .} 
proc getUInt32*(value: cuint): cuint {. importc: "PG_GETARG_UINT32" .} 
proc getInt16*(value: cuint): cshort   {. importc: "PG_GETARG_INT16" .} 
proc getUInt16*(value: cuint): cushort {. importc: "PG_GETARG_UINT16" .} 

proc getChar*(value: cuint): cchar {. importc: "PG_GETARG_CHAR" .} 
proc getBool*(value: cuint): cchar {. importc: "PG_GETARG_BOOL" .} 

proc getFloat4*(value: cuint): cfloat {. importc: "PG_GETARG_FLOAT4"  .}
proc getFloat8*(value: cuint): cdouble {. importc: "PG_GETARG_FLOAT8" .}

# Return types declaration

template returnInt32*(value: typed) = {. emit: ["""PG_RETURN_INT32(""",value, ");" ].}
template returnInt36*(value: typed) = {. emit: ["""PG_RETURN_INT16(""",value, ");" ].}
template returnUInt32*(value: typed) = {. emit: ["""PG_RETURN_UINT32(""",value, ");" ].}
template returnUInt16*(value: typed) = {. emit: ["""PG_RETURN_UINT16(""",value, ");" ].}

template returnChar*(value: typed) = {. emit: ["""PG_RETURN_CHAR(""",value, ");" ].}
template returnBool*(value: typed) = {. emit: ["""PG_RETURN_BOOL(""",value, ");" ].}

template returnFloat4*(value: typed) = {. emit: ["""PG_RETURN_FLOAT4(""",value, ");" ].}
template returnFloat8*(value: typed) = {. emit: ["""PG_RETURN_FLOAT8(""",value, ");" ].}

{.pop.}