{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

import ../datatypes/basic
import ../syscache

{.push header: "catalog/pg_type_d.h".}

var
  Anum_pg_type_oid*           {.importc.}: int16
  Anum_pg_type_typname*       {.importc.}: int16
  Anum_pg_type_typowner*      {.importc.}: int16
  Anum_pg_type_typlen*        {.importc.}: int16
  Anum_pg_type_typtype*       {.importc.}: int16
  Anum_pg_type_typarray*      {.importc.}: int16
  Anum_pg_type_typndims*      {.importc.}: int16
  Anum_pg_type_typdefault*    {.importc.}: int16
  Anum_pg_type_typdefaultbin* {.importc.}: int16

var TEXTOID* {.importc.}: Oid

{.pop.}

template get_pg_type_oid*(ttuple: typed): Oid =
  block:
    let pgxTup = ttuple
    var res = 0.Oid
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_oid, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetObjectId(datum)
    res

template get_pg_type_name*(ttuple: typed): cstring =
  block:
    let pgxTup = ttuple
    var res: cstring = nil
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typname, addr(attrIsNull))
      if not attrIsNull:
        let namePtr = DatumGetName(datum)
        if namePtr != nil:
          res = cast[cstring](addr namePtr.data[0])
    res

template get_pg_type_owner*(ttuple: typed): Oid =
  block:
    let pgxTup = ttuple
    var res = 0.Oid
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typowner, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetObjectId(datum)
    res

template get_pg_type_len*(ttuple: typed): int16 =
  block:
    let pgxTup = ttuple
    var res = 0'i16
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typlen, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetInt16(datum)
    res

template get_pg_type_type*(ttuple: typed): char =
  block:
    let pgxTup = ttuple
    var res = '\0'
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typtype, addr(attrIsNull))
      if not attrIsNull:
        res = char(DatumGetChar(datum))
    res

template get_pg_type_array*(ttuple: typed): Oid =
  block:
    let pgxTup = ttuple
    var res = 0.Oid
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typarray, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetObjectId(datum)
    res

template get_pg_type_ndims*(ttuple: typed): int32 =
  block:
    let pgxTup = ttuple
    var res = 0'i32
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typndims, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetInt32(datum)
    res

template get_pg_type_defaultvalue*(ttuple: typed): cstring =
  block:
    let pgxTup = ttuple
    var res: cstring = nil
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(TYPEOID, pgxTup, Anum_pg_type_typdefault, addr(attrIsNull))
      if not attrIsNull:
        res = TextDatumGetCString(datum)
    res

