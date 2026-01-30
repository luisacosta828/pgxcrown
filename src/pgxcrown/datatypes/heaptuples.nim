from basic import Oid,Datum

{.push header: "access/htup_details.h" .}
type
  DatumTupleFields {.importc: "struct DatumTupleFields".} = object
    datum_len*: int32
    datum_typmod*: int32
    datum_typeid*: Oid

  HeapTupleHeaderChoice {.importc: "union".} = object
    t_heap:  pointer
    t_datum*: DatumTupleFields

  HeapTupleHeaderData* {.importc: "HeapTupleHeaderData".} = object
    t_choice*:   HeapTupleHeaderChoice
    t_ctid*:     pointer # ItemPointerData
    t_infomask2*: uint16
    t_infomask*:  uint16
    t_hoff*:      uint8

  HeapTupleHeader* = ptr HeapTupleHeaderData 

{.pop.}

{.push header: "access/tupdesc.h".}
type
  TupleDesc* {.importc: "TupleDesc".} = ref object
    natts*: int

proc DecrTupleDescRefCount*(tup: TupleDesc) {.importc.}

{.pop.}

{.push header: "utils/typcache.h".}
proc lookup_rowtype_tupdesc*(type_id: Oid, typmod: cint): TupleDesc {.importc.}
{.pop.}


{.push header: "executor/executor.h" .}
proc GetAttributeByNum(tup: HeapTupleHeader, attrno: cint, isNull: var bool): Datum {.importc.}
{.pop.}

{.push header: "fmgr.h".}
proc getHeapTupleHeader*(value: cuint): HeapTupleHeader {.importc: "PG_GETARG_HEAPTUPLEHEADER" .}
{.pop.}

proc get_tuple_attr*[T](element: HeapTupleHeader, row: TupleDesc, idx: cint): T =
  var isNull: bool
  if not row.isNil:
    var attr = GetAttributeByNum(element, idx, isNull)
    if not isNull:
      result = attr
    else:
      result = default(T)

proc getTypeId2*(tup: HeapTupleHeader): Oid  =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typeid
  return 0.Oid

proc getTypeMod2*(tup: HeapTupleHeader): cint  =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typmod
  return -1
