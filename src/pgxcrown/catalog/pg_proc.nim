{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

import ../datatypes/basic
import ../datatypes/arrays
import ../syscache

{.push header: "postgres.h".}
proc pgxDatumGetBool(x: Datum): bool {.importc: "DatumGetBool".}
{.pop.}

{.push header: "funcapi.h".}
proc get_func_input_arg_names*(proargnames, proargmodes: Datum, arg_names: var cstringArray): cint {.importc.}
{.pop.}

{.push header: "catalog/pg_proc_d.h".}

var
  #This tells the function handler how to invoke the function. It might be the actual source code of the function for interpreted languages, a link symbol, a file name, or just about anything else, depending on the implementation language/call convention
  Anum_pg_proc_prosrc* {.importc.}: int16

  #Name of the function
  Anum_pg_proc_proname* {.importc.}: int16

  #Implementation language or call interface of this function
  Anum_pg_proc_prolang* {.importc.}: int16

  #f for a normal function, p for a procedure, a for an aggregate function, or w for a window function
  Anum_pg_proc_prokind* {.importc.}: int16
  
  #Function returns null if any call argument is null. In that case the function won't actually be called at all. Functions that are not “strict” must be prepared to handle null inputs
  Anum_pg_proc_proisstrict* {.importc.}: int16

  #Number of input arguments
  Anum_pg_proc_pronargs* {.importc.}: int16

  #Number of arguments that have defaults
  Anum_pg_proc_pronargdefaults* {.importc.}: int16
  
  #Data type of the return value
  Anum_pg_proc_prorettype* {.importc.}: int16

  #An array of the data types of the function arguments
  Anum_pg_proc_proargtypes* {.importc.}: int16

  #An array of the names of the function arguments. Arguments without a name are set to empty strings in the array
  Anum_pg_proc_proargnames* {.importc.}: int16

  #Function returns a set (true for RETURNS SETOF / RETURNS TABLE)
  Anum_pg_proc_proretset* {.importc.}: int16

{.pop.}

template get_pg_proc_retset*(ttuple: typed): bool =
  block:
    let pgxTup = ttuple
    var res = false
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proretset, addr(attrIsNull))
      if not attrIsNull:
        res = pgxDatumGetBool(datum)
    res

template get_pg_proc_src*(ttuple: typed): cstring =
  block:
    let pgxTup = ttuple
    var res: cstring = nil
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_prosrc, addr(attrIsNull))
      if not attrIsNull:
        res = TextDatumGetCString(datum)
    res

template get_pg_proc_name*(ttuple: typed): cstring =
  block:
    let pgxTup = ttuple
    var res: cstring = nil
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proname, addr(attrIsNull))
      if not attrIsNull:
        let fn_name = DatumGetName(datum)
        if fn_name != nil:
          res = cast[cstring](addr fn_name.data[0])
    res

template get_pg_proc_kind*(ttuple: typed): char =
  block:
    let pgxTup = ttuple
    var res = '\0'
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_prokind, addr(attrIsNull))
      if not attrIsNull:
        res = char(DatumGetChar(datum))
    res

template get_pg_proc_is_strict*(ttuple: typed): bool =
  block:
    let pgxTup = ttuple
    var res = false
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proisstrict, addr(attrIsNull))
      if not attrIsNull:
        res = pgxDatumGetBool(datum)
    res

template get_pg_proc_nargs*(ttuple: typed): int16 =
  block:
    let pgxTup = ttuple
    var res = 0'i16
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_pronargs, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetInt16(datum)
    res

template get_pg_proc_default_nargs*(ttuple: typed): int16 =
  block:
    let pgxTup = ttuple
    var res = 0'i16
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_pronargdefaults, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetInt16(datum)
    res

template get_pg_proc_rettype*(ttuple: typed): Oid =
  block:
    let pgxTup = ttuple
    var res = 0.Oid
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_prorettype, addr(attrIsNull))
      if not attrIsNull:
        res = DatumGetObjectId(datum)
    res

template get_pg_proc_argnames*(ttuple: typed): seq[string] =
  block:
    let pgxTup = ttuple
    var res: seq[string] = @[]
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proargnames, addr(attrIsNull))
      if not attrIsNull:
        var arg_names: cstringArray = nil
        let nelems = get_func_input_arg_names(datum, Datum(0), arg_names)
        if nelems > 0 and arg_names != nil:
          res = arg_names.cstringArrayToSeq(nelems.int)
    res

template get_pg_proc_argtypes*(ttuple: typed): ptr UncheckedArray[Oid] =
  block:
    let pgxTup = ttuple
    var res: ptr UncheckedArray[Oid] = nil
    if pgxTup != nil:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proargtypes, addr(attrIsNull))
      if not attrIsNull:
        let fn_args_types = cast[ptr oidvector](DatumGetPointer(datum))
        if fn_args_types != nil:
          res = addr(fn_args_types.values)
    res

template get_pg_proc_arg_oid*(ttuple: typed, arg_idx: int): Oid =
  block:
    let pgxTup = ttuple
    var res = 0.Oid
    if pgxTup != nil and arg_idx >= 0:
      var attrIsNull = false
      let datum = SysCacheGetAttr(PROCOID, pgxTup, Anum_pg_proc_proargtypes, addr(attrIsNull))
      if not attrIsNull:
        let fn_args_types = cast[ptr oidvector](DatumGetPointer(datum))
        if fn_args_types != nil and arg_idx < fn_args_types.dim1.int:
          res = fn_args_types.values[arg_idx]
    res

template asIntptr(vector: ptr Oid): int = cast[int](vector)

template asOid*(address: int): Oid =
  (cast[ptr Oid](address))[]

proc `+`*(vector: ptr Oid, offset: int): int {.inline.} =
  vector.asIntptr + (sizeof(Oid) * offset)
