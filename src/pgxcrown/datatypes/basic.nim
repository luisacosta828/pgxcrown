# Basic Data Types definitions from postgres.h


{.push header: "postgres.h".}

type
  Datum* {.importc: "Datum".} = cuint
  
  Text* {.importc: "text".} = object
    vl_len:   array[4, char]
    vl_dat*:  array[256, char]
 
  Pointer* {.importc: "Pointer".} = cstring
  
  Oid* {.importc: "Oid".} = cuint
  
  const_char* {.importc: "const char*".} = cstring
  
  PDatum* = ptr Datum
  
  POid* = ptr Oid

  NameData* {.importc.} = object
    data*: array[64, char]
  
  Name* = ptr NameData

  oidvector* {.importc.} = object
    vl_len {.importc: "vl_len_".}: int32
    ndim*: int
    dataoffset*: int32
    elemtype*: Oid
    dim1*: int 
    lbound1: int
    values*: ptr Oid


proc cstring_to_text*(s: const_char): Text {.importc.}
proc NameStr*(name: NameData): cstring {.importc.}
proc DatumGetObjectId*(datum_id: Datum): Oid {.importc.}
proc DatumGetInt32*(x: Datum): int32 {.importc.}
proc DatumGetInt16*(x: Datum): int16 {.importc.}
#proc DatumGetInt8*(x: Datum): int8 {.importc.}
proc DatumGetUInt32*(x: Datum): uint32 {.importc.}
proc DatumGetUInt16*(x: Datum): uint16 {.importc.}
proc DatumGetUInt8*(x: Datum): uint8 {.importc.}
proc DatumGetChar*(x: Datum): cchar {.importc.}
proc DatumGetBool*(x: Datum): cchar | bool {.importc.}
proc DatumGetFloat4*(x: Datum): cfloat | float32 | float {.importc.}
proc DatumGetPointer*(x: Datum): Pointer {.importc.}
proc DatumGetCString*(x: Datum): cstring {.importc.}
proc DatumGetName*(x: Datum): Name {.importc.}

proc ObjectIdGetDatum*(id: Oid): Datum {.importc.}
proc Int32GetDatum*(x: int32 | int ): Datum {.importc.}
proc Int16GetDatum*(x: int16 ): Datum {.importc.}
proc Int8GetDatum*(x: int8 ): Datum {.importc.}
proc UInt32GetDatum*(x: uint32 | uint): Datum {.importc.}
proc UInt16GetDatum*(x: uint16): Datum {.importc.}
proc UInt8GetDatum*(x: uint8): Datum {.importc.}
proc CharGetDatum*(x: cchar): Datum {.importc.}
proc BoolGetDatum*(x: cchar | bool): Datum {.importc.}
proc Float4GetDatum*(x: cfloat | float32 | float): Datum {.importc.}
proc PointerGetDatum*(x: Pointer): Datum {.importc.}
proc CStringGetDatum*(x: cstring): Datum {.importc.}
proc NameGetDatum*(x: Name): Datum {.importc.}
{.pop.}

{.push header: "utils/builtins.h".}
proc TextDatumGetCString*(x: Datum): cstring {.importc.} 
{.pop.}

# Basic Data Types definitions from fmgr.h
type
  PGType* = proc(): Datum {.cdecl, noSideEffect, gcsafe.}

{.push header: "fmgr.h".}

type

  FmgrInfo {.importc: "FmgrInfo".} = object
    fn_oid*: Oid

  FunctionCallInfoBaseData {. importc .} = object
    nargs*: cshort
    flinfo*: ptr FmgrInfo

  #Standard parameter list for fmgr-compatible functions
  FunctionCallInfo* = ptr FunctionCallInfoBaseData



template getFnOid*(fcinfo: FunctionCallInfo): Oid = 
  fcinfo[].flinfo[].fn_oid

# Get argument type value declaration

proc getInt32*(value: cuint): cint {.importc: "PG_GETARG_INT32".}

proc getUInt32*(value: cuint): cuint {.importc: "PG_GETARG_UINT32".}

proc getInt16*(value: cuint): cshort {.importc: "PG_GETARG_INT16".}

proc getUInt16*(value: cuint): cushort {.importc: "PG_GETARG_UINT16".}

proc getCString*(value: cuint): cstring {.importc: "PG_GETARG_CSTRING".}

proc getBool*(value: cuint): cchar {.importc: "PG_GETARG_BOOL".}

proc getFloat4*(value: cuint): cfloat {.importc: "PG_GETARG_FLOAT4".}

proc getFloat8*(value: cuint): cdouble {.importc: "PG_GETARG_FLOAT8".}


# Return types declaration


template returnInt32*(value: typed) = {.emit: ["""PG_RETURN_INT32(""", value, ");"].}

template returnInt16*(value: typed) = {.emit: ["""PG_RETURN_INT16(""", value, ");"].}

template returnUInt32*(value: typed) = {.emit: ["""PG_RETURN_UINT32(""", value, ");"].}

template returnUInt16*(value: typed) = {.emit: ["""PG_RETURN_UINT16(""", value, ");"].}

template returnBool*(value: typed) = {.emit: ["""PG_RETURN_BOOL(""", value, ");"].}

template returnFloat4*(value: typed) = {.emit: ["""PG_RETURN_FLOAT4(""", value, ");"].}

template returnFloat8*(value: typed) = {.emit: ["""PG_RETURN_FLOAT8(""", value, ");"].}

template returnVarchar*(value: typed) = {.emit: ["""PG_RETURN_VARCHAR_P(""", value, ");"].}

template returnCString*(value: typed) = {.emit: ["""PG_RETURN_CSTRING(""", value, ");"].}


proc DirectFunctionCall1*(fn: PGType, arg1: Datum): Datum {.importc.}
proc DirectFunctionCall2*(fn: PGType, arg1: Datum, arg2: Datum): Datum {.importc.}
proc DirectFunctionCall3*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum): Datum {.importc.}
proc DirectFunctionCall4*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum): Datum {.importc.}
proc DirectFunctionCall5*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum, arg5: Datum): Datum {.importc.}
proc DirectFunctionCall6*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum, arg5: Datum, arg6: Datum): Datum {.importc.}
proc DirectFunctionCall7*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum, arg5: Datum, arg6: Datum, arg7: Datum): Datum {.importc.}
proc DirectFunctionCall8*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum, arg5: Datum, arg6: Datum, arg7: Datum, arg8: Datum): Datum {.importc.}
proc DirectFunctionCall9*(fn: PGType, arg1: Datum, arg2: Datum, arg3: Datum, arg4: Datum, arg5: Datum, arg6: Datum, arg7: Datum, arg8: Datum, arg9: Datum): Datum {.importc.}




{.pop.}
