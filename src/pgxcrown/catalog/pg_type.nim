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
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_oid, addr(attrIsNull))
    oid   = DatumGetObjectId(datum)
  oid

template get_pg_type_name*(ttuple: typed): cstring =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typname, addr(attrIsNull))
    name  = DatumGetName(datum)
  NameStr(name[])

template get_pg_type_owner*(ttuple: typed): Oid =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typowner, addr(attrIsNull))
    oid   = DatumGetObjectId(datum)
  oid 

template get_pg_type_len*(ttuple: typed): int16 =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typlen, addr(attrIsNull))
    typlen = DatumGetInt16(datum)
  typlen

template get_pg_type_type*(ttuple: typed): char =
  var 
    attrIsNull = false
    datum  = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typtype, addr(attrIsNull))
    argtype = DatumGetChar(datum)
  argtype

template get_pg_type_array*(ttuple: typed): Oid =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typarray, addr(attrIsNull))
    oid   = DatumGetObjectId(datum)
  oid

template get_pg_type_ndims*(ttuple: typed): int32 =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typndims, addr(attrIsNull))
    ndims   = DatumGetInt32(datum)
  ndims

template get_pg_type_defaultvalue*(ttuple: typed): cstring =
  var 
    attrIsNull = false
    datum = SysCacheGetAttr(TYPEOID, ttuple, Anum_pg_type_typdefault, addr(attrIsNull))
  var default_text   = TextDatumGetCString(datum)
  default_text

