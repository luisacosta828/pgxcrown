import ../datatypes/basic

{.push header: "catalog/pg_type_d.h".}

var 
  Anum_pg_type_oid        {.importc.}: cuint
  Anum_pg_type_typname    {.importc.}: cuint
  Anum_pg_type_typowner   {.importc.}: cuint
  Anum_pg_type_typlen     {.importc.}: cuint
  Anum_pg_type_typtype    {.importc.}: cuint
  Anum_pg_type_typarray   {.importc.}: cuint
  Anum_pg_type_typndims   {.importc.}: cuint
  Anum_pg_type_typdefault {.importc.}: cuint
  Anum_pg_type_typdefaultbin {.importc.}: cuint


var TEXTOID* {.importc.}: Oid

{.pop.}

template get_pg_type_oid*(ttuple: typed): Oid =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_oid, addr(is_null))
    oid   = DatumGetObjectId(datum)
  oid

template get_pg_type_name*(ttuple: typed): cstring =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typname, addr(is_null))
    name  = DatumGetName(datum)
  NameStr(name[])

template get_pg_type_owner*(ttuple: typed): Oid =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typowner, addr(is_null))
    oid   = DatumGetObjectId(datum)
  oid 

template get_pg_type_len*(ttuple: typed): int16 =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typlen, addr(is_null))
    typlen = DatumGetInt16(datum)
  typlen

template get_pg_type_type*(ttuple: typed): char =
  var 
    datum  = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typtype, addr(is_null))
    argtype = DatumGetChar(datum)
  argtype

template get_pg_type_array*(ttuple: typed): Oid =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typarray, addr(is_null))
    oid   = DatumGetObjectId(datum)
  oid

template get_pg_type_ndims*(ttuple: typed): int32 =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typndims, addr(is_null))
    ndims   = DatumGetInt32(datum)
  ndims

template get_pg_type_defaultvalue*(ttuple: typed): cstring =
  var 
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typdefault, addr(is_null))
  var default_text   = TextDatumGetCString(datum)
  default_text

