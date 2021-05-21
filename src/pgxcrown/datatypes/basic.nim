# Basic Data Types definitions from postgres.h

{. push header: "postgres.h" .}

type 
    Datum* {.importc: "Datum".} = cuint
    Text* {.importc: "text".} = ref object
    Oid*  {.importc: "Oid".} = cuint
    const_char* {.importc: "const char*".} = cstring
    PDatum* = ptr Datum
    POid* = ptr Oid

proc cstring_to_text*(s: const_char): Text {.importc: "cstring_to_text".}

proc ObjectIdGetDatum*(id: Oid):Datum {. importc .}
proc DatumGetObjectId*(datum_id: Datum): Oid {. importc .}
{. pop .}


# Basic Data Types definitions from fmgr.h

{. push header: "fmgr.h" .}

type

    FmgrInfo {.importc: "FmgrInfo" .} = object
        fn_oid*: Oid
 
    FunctionCallInfoData {.importc: "FunctionCallInfoData".} = object
        nargs*: cshort
        flinfo*: ptr FmgrInfo

    FunctionCallInfo* = ptr FunctionCallInfoData

# Get argument type value declaration
    
proc getInt32*(value: cuint): cint   {. importc: "PG_GETARG_INT32" .} 
proc getUInt32*(value: cuint): cuint {. importc: "PG_GETARG_UINT32" .} 
proc getInt16*(value: cuint): cshort   {. importc: "PG_GETARG_INT16" .} 
proc getUInt16*(value: cuint): cushort {. importc: "PG_GETARG_UINT16" .} 

proc getCString*(value: cuint): cstring {.importc: "PG_GETARG_CSTRING".}
proc getBool*(value: cuint): cchar {. importc: "PG_GETARG_BOOL" .} 

proc getFloat4*(value: cuint): cfloat {. importc: "PG_GETARG_FLOAT4"  .}
proc getFloat8*(value: cuint): cdouble {. importc: "PG_GETARG_FLOAT8" .}

# Return types declaration

template returnInt32*(value: typed) = {. emit: ["""PG_RETURN_INT32(""",value, ");" ].}
template returnInt16*(value: typed) = {. emit: ["""PG_RETURN_INT16(""",value, ");" ].}
template returnUInt32*(value: typed) = {. emit: ["""PG_RETURN_UINT32(""",value, ");" ].}
template returnUInt16*(value: typed) = {. emit: ["""PG_RETURN_UINT16(""",value, ");" ].}

template returnBool*(value: typed) = {. emit: ["""PG_RETURN_BOOL(""",value, ");" ].}

template returnFloat4*(value: typed) = {. emit: ["""PG_RETURN_FLOAT4(""",value, ");" ].}
template returnFloat8*(value: typed) = {. emit: ["""PG_RETURN_FLOAT8(""",value, ");" ].}

template returnVarchar*(value: typed) = {. emit: ["""PG_RETURN_VARCHAR_P(""",value, ");" ].}
template returnCString*(value: typed) = {. emit: ["""PG_RETURN_CSTRING(""",value, ");" ].}

{.pop.}
