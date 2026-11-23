from basic import Oid, Datum, NullDatum, `==`, isZero, NameData, OidOutputFunctionCall, PointerGetDatum,
    DatumGetPointer, Pointer,
  Int8GetDatum, Int32GetDatum, Int64GetDatum, Int16GetDatum, UInt8GetDatum,
  UInt16GetDatum, UInt64GetDatum, Float4GetDatum, Float8GetDatum, BoolGetDatum,
  CharGetDatum, ObjectIdGetDatum, CStringGetTextDatum, TextDatumGetCString,
  DatumToInt32, DatumToInt, DatumToInt64,
  DatumGetFloat8, DatumGetChar, DatumGetObjectId, DatumToCString,
  DatumGetInt32, DatumGetInt64, DatumGetInt16, DatumGetUInt64, DatumGetUInt16,
  DatumGetUInt8, DatumGetFloat4, DatumGetBool, palloc, MemoryContextSwitchTo

from jsonb import JsonNodeToDatum, DatumToJsonNode
from strings import PgText, getPgText, returnPgText
from bytea import PgBytea, getPgBytea, returnPgBytea
from uuid import PgUuid, getPgUuid, returnPgUuid
from temporal import PgDate, PgTimestamp, PgTimestampTz, PgInterval,
  getPgDate, returnPgDate, getPgTimestamp, returnPgTimestamp,
  getPgTimestampTz, returnPgTimestampTz, getPgInterval, returnPgInterval
from numeric import PgNumeric, getPgNumeric, returnPgNumeric

import std/[options, json, strutils, typetraits, os]

const PgxCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxCHeadersDir).}

{.push header: "postgres.h".}
proc htup_pfree(p: pointer) {.importc: "pfree".}
{.pop.}

{.push header: "pgx_types.h".}
proc pgx_lookup_type_oid(typname: cstring): Oid {.importc.}
proc pgx_get_array_type_oid(elemOid: Oid): Oid {.importc.}
proc pgx_enum_label_to_oid(typname: cstring, label: cstring): Oid {.importc.}
proc pgx_enum_oid_to_label(enumOid: Oid): cstring {.importc.}
proc pgxDirectCall0*(fn: pointer, retIsNull: ptr bool = nil): Datum {.importc: "pgx_direct_call0", noSideEffect, gcsafe, tags: [].}
proc pgxDirectCallN*(fn: pointer, nargs: cint, args: ptr Datum, nulls: ptr bool, retIsNull: ptr bool = nil): Datum {.importc: "pgx_direct_call_n", noSideEffect, gcsafe, tags: [].}
{.pop.}

{.push header: "utils/array.h".}
proc htup_DatumGetArrayTypeP(x: Datum): pointer {.importc: "DatumGetArrayTypeP".}
proc htup_deconstruct_array(
  arr: pointer, elmtype: Oid, elmlen: cint, elmbyval: bool, elmalign: cchar,
  elemsp: ptr ptr Datum, nullsp: ptr ptr bool, nelemsp: ptr cint
) {.importc: "deconstruct_array".}
proc htup_construct_array(
  elems: ptr Datum, nelems: cint, elmtype: Oid, elmlen: cint, elmbyval: bool,
      elmalign: cchar
): pointer {.importc: "construct_array".}
{.pop.}

{.push header: "access/htup_details.h".}
type
  DatumTupleFields {.importc: "struct DatumTupleFields".} = object
    datum_len*: int32
    datum_typmod*: int32
    datum_typeid*: Oid

  HeapTupleHeaderChoice {.importc: "union".} = object
    t_heap: pointer
    t_datum*: DatumTupleFields

  HeapTupleHeaderData* {.importc: "HeapTupleHeaderData".} = object
    t_choice*: HeapTupleHeaderChoice
    t_ctid*: pointer # ItemPointerData
    t_infomask2*: uint16
    t_infomask*: uint16
    t_hoff*: uint8

  HeapTupleHeader* = ptr HeapTupleHeaderData

  HeapTupleData* {.importc: "HeapTupleData".} = object
    t_len*: uint32
    t_self*: pointer
    t_tableOid*: Oid
    t_data*: HeapTupleHeader

  HeapTuple* = ptr HeapTupleData

  FormData_pg_attribute* {.importc: "FormData_pg_attribute".} = object
    attrelid*: Oid
    attname*: NameData
    atttypid*: Oid
    attnum*: int16
    attisdropped*: bool

  Form_pg_attribute* = ptr FormData_pg_attribute

proc heap_form_tuple*(tupleDescriptor: pointer, values: ptr Datum,
    isnull: ptr bool): HeapTuple {.importc: "heap_form_tuple".}
proc heap_freetuple*(htup: HeapTuple) {.importc: "heap_freetuple".}

{.pop.}

proc HeapTupleGetDatum*(htup: HeapTuple): Datum {.inline.} =
  if htup.isNil: return Datum(0)
  return PointerGetDatum(cast[Pointer](htup.t_data))

{.push header: "access/tupdesc.h".}
type
  TupleDesc* {.importc: "TupleDesc".} = pointer
  TupleDescData* {.importc: "struct TupleDescData".} = object
    natts*: cint

  TupleDescStruct* = ptr TupleDescData

proc DecrTupleDescRefCount*(tup: TupleDesc) {.importc.}
proc CreateTemplateTupleDesc*(natts: cint): TupleDesc {.importc: "CreateTemplateTupleDesc".}
proc TupleDescInitEntry*(desc: TupleDesc, attnum: int16, attname: cstring,
    oidtypeid: Oid, typmod: int32,
    attdim: cint) {.importc: "TupleDescInitEntry".}
proc BlessTupleDesc*(tupdesc: TupleDesc): TupleDesc {.importc: "BlessTupleDesc".}
proc TupleDescAttr*(tupdesc: TupleDesc, i: cint): Form_pg_attribute {.importc: "TupleDescAttr".}
{.pop.}

{.push header: "utils/typcache.h".}
proc lookup_rowtype_tupdesc*(type_id: Oid, typmod: cint): TupleDesc {.importc.}
proc lookup_rowtype_tupdesc_noerror*(type_id: Oid, typmod: int32,
    noError: bool): TupleDesc {.importc: "lookup_rowtype_tupdesc_noerror".}
{.pop.}

{.push header: "executor/executor.h".}
proc GetAttributeByNum*(tup: HeapTupleHeader, attrno: cint,
    isNull: var bool): Datum {.importc.}
{.pop.}

{.push header: "fmgr.h".}
proc getHeapTupleHeader*(value: cuint): HeapTupleHeader {.importc: "PG_GETARG_HEAPTUPLEHEADER".}
proc DatumGetHeapTupleHeader*(d: Datum): HeapTupleHeader {.importc: "DatumGetHeapTupleHeader".}
{.pop.}

proc sqlTypeNameFor*[T](): string {.inline, noSideEffect, tags: [].} =
  ## Returns the unqualified Nim type name matching SQL `CREATE TYPE` declarations.
  let raw = typetraits.name(T)
  if "." in raw: raw.split('.')[^1] else: raw

proc oidToEnum*[E: enum](oid: Oid): E {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a PostgreSQL `pg_enum.oid` Datum value to its corresponding Nim enum value.
  if oid == 0.Oid:
    return default(E)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let cs = pgx_enum_oid_to_label(oid)
      if cs == nil:
        raise newException(ValueError, "Unknown PostgreSQL enum OID " & $uint32(oid) & " for enum " & sqlTypeNameFor[E]())
      let label = $cs
      htup_pfree(cast[pointer](cs))
      parseEnum[E](label)

proc enumToDatum*[E: enum](val: E): Datum {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Resolves a Nim enum value to its PostgreSQL `pg_enum.oid` Datum via catalog lookup.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let tname = sqlTypeNameFor[E]()
      let label = $val
      let oid = pgx_enum_label_to_oid(cstring(tname), cstring(label))
      if oid == 0.Oid:
        raise newException(ValueError, "PostgreSQL enum type/value not found for " & tname & "." & label)
      ObjectIdGetDatum(oid)

proc get_tuple_attr*[T](element: HeapTupleHeader, row: TupleDesc,
    idx: cint): T =
  var isNull: bool
  if not row.isNil and not element.isNil:
    var attr = GetAttributeByNum(element, idx, isNull)
    if not isNull:
      result = attr
    else:
      result = default(T)

proc getTypeId*(tup: HeapTupleHeader): Oid =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typeid
  return 0.Oid

proc getTypeMod*(tup: HeapTupleHeader): cint =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typmod
  return -1

{.push header: "utils/lsyscache.h".}
proc getTypeOutputInfo*(typeId: Oid, typOutput: var Oid,
    typIsVarlena: var bool) {.importc: "getTypeOutputInfo".}
{.pop.}

proc getTupleDesc*(heapTuple: HeapTupleHeader): TupleDesc {.inline.} =
  var
    tupTypeId = getTypeId(heapTuple)
    tupTypMod = getTypeMod(heapTuple)

  result = lookup_rowtype_tupdesc(tupTypeId, tupTypMod)

proc getTupleStringAttr*(element: HeapTupleHeader, row: TupleDesc,
    idx: cint): string =
  var isNull: bool
  if not row.isNil and not element.isNil:
    let d = GetAttributeByNum(element, idx, isNull)
    if not isNull and d != Datum(0):
      let attr = TupleDescAttr(row, idx - 1)
      if attr != nil:
        var outputProc: Oid
        var isVarlena: bool
        getTypeOutputInfo(attr.atttypid, outputProc, isVarlena)
        if outputProc != 0:
          let cs = OidOutputFunctionCall(outputProc, d)
          if cs != nil:
            result = $cs
            htup_pfree(cs)
            return result
  return ""

# -----------------------------------------------------------------------------
# High-Level Generic Deserializer: HeapTupleHeader -> object
# -----------------------------------------------------------------------------

proc nextValidTableColumn*(tupDesc: TupleDesc,
    startIdx: cint): cint {.inline.} =
  result = startIdx
  let natts = if tupDesc != nil: cast[TupleDescStruct](tupDesc).natts else: 0
  while result <= natts:
    let attr = TupleDescAttr(tupDesc, result - 1)
    if attr != nil and attr.attisdropped:
      result += 1
    else:
      break

proc getTupleAttrOid(tupDesc: TupleDesc, idx: cint): Oid {.inline, noSideEffect, tags: [].} =
  if tupDesc == nil or idx < 1 or idx > cast[TupleDescStruct](tupDesc).natts:
    return 0.Oid
  let attr = TupleDescAttr(tupDesc, idx - 1)
  if attr == nil: return 0.Oid
  attr.atttypid

proc arrayLayoutForElem[ElemT](): tuple[oid: Oid, len: cint, byVal: bool, align: cchar] =
  when ElemT is int32 or ElemT is cint or ElemT is int: (23.Oid, 4'i32, true, 'i'.cchar)
  elif ElemT is int64 or ElemT is clonglong: (20.Oid, 8'i32, true, 'd'.cchar)
  elif ElemT is int16 or ElemT is cshort or ElemT is uint16: (21.Oid, 2'i32, true, 's'.cchar)
  elif ElemT is uint64: (20.Oid, 8'i32, true, 'd'.cchar)
  elif ElemT is uint32 or ElemT is uint or ElemT is cuint: (26.Oid, 4'i32, true, 'i'.cchar)
  elif ElemT is float64 or ElemT is float or ElemT is cdouble: (701.Oid, 8'i32, true, 'd'.cchar)
  elif ElemT is float32 or ElemT is cfloat: (700.Oid, 4'i32, true, 'i'.cchar)
  elif ElemT is bool: (16.Oid, 1'i32, true, 'c'.cchar)
  elif ElemT is PgBytea: (17.Oid, -1'i32, false, 'i'.cchar)
  elif ElemT is PgUuid: (2950.Oid, 16'i32, false, 'c'.cchar)
  elif ElemT is PgDate: (1082.Oid, 4'i32, true, 'i'.cchar)
  elif ElemT is PgTimestamp: (1114.Oid, 8'i32, true, 'd'.cchar)
  elif ElemT is PgTimestampTz: (1184.Oid, 8'i32, true, 'd'.cchar)
  elif ElemT is PgInterval: (1186.Oid, 16'i32, false, 'd'.cchar)
  elif ElemT is PgNumeric: (1700.Oid, -1'i32, false, 'i'.cchar)
  elif ElemT is JsonNode: (3802.Oid, -1'i32, false, 'i'.cchar)
  elif ElemT is enum: (pgx_lookup_type_oid(cstring(sqlTypeNameFor[ElemT]())), 4'i32, true, 'i'.cchar)
  else: (25.Oid, -1'i32, false, 'i'.cchar)

proc unpackDatumToElem[ElemT](d: Datum): ElemT =
  when ElemT is int32 or ElemT is cint or ElemT is int: ElemT(DatumGetInt32(d))
  elif ElemT is int64 or ElemT is clonglong: ElemT(DatumGetInt64(d))
  elif ElemT is int16 or ElemT is cshort: ElemT(DatumGetInt16(d))
  elif ElemT is uint16: uint16(DatumGetUInt16(d))
  elif ElemT is uint64: DatumGetUInt64(d)
  elif ElemT is uint32 or ElemT is uint or ElemT is cuint: ElemT(DatumGetObjectId(d))
  elif ElemT is float64 or ElemT is float or ElemT is cdouble: ElemT(DatumGetFloat8(d))
  elif ElemT is float32 or ElemT is cfloat: ElemT(DatumGetFloat4(d))
  elif ElemT is bool: DatumGetBool(d)
  elif ElemT is PgBytea: getPgBytea(d)
  elif ElemT is PgUuid: getPgUuid(d)
  elif ElemT is PgDate: getPgDate(d)
  elif ElemT is PgTimestamp: getPgTimestamp(d)
  elif ElemT is PgTimestampTz: getPgTimestampTz(d)
  elif ElemT is PgInterval: getPgInterval(d)
  elif ElemT is PgNumeric: getPgNumeric(d)
  elif ElemT is JsonNode: DatumToJsonNode(d)
  elif ElemT is enum: oidToEnum[ElemT](DatumGetObjectId(d))
  elif ElemT is PgText: getPgText(d)
  elif ElemT is distinct: ElemT(unpackDatumToElem[distinctBase(ElemT)](d))
  else:
    let elemCs = TextDatumGetCString(d)
    if elemCs != nil:
      let s = $elemCs
      htup_pfree(elemCs)
      s
    else:
      ""

proc extractField*[FieldT](th: HeapTupleHeader, tupDesc: TupleDesc, idx: cint,
    rawDatum: Datum): FieldT {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      when FieldT is bool: DatumGetBool(rawDatum)
      elif FieldT is int8: int8(DatumGetChar(rawDatum))
      elif FieldT is uint8: DatumGetUInt8(rawDatum)
      elif FieldT is int16 or FieldT is cshort: FieldT(DatumGetInt16(rawDatum))
      elif FieldT is uint16: DatumGetUInt16(rawDatum)
      elif FieldT is int32 or FieldT is cint: FieldT(DatumGetInt32(rawDatum))
      elif FieldT is int:
        let colOid = getTupleAttrOid(tupDesc, idx)
        if colOid == 23.Oid: int(DatumGetInt32(rawDatum))
        elif colOid == 21.Oid: int(DatumGetInt16(rawDatum))
        else: int(DatumGetInt64(rawDatum))
      elif FieldT is int64 or FieldT is clonglong: FieldT(DatumGetInt64(rawDatum))
      elif FieldT is uint64: DatumGetUInt64(rawDatum)
      elif FieldT is uint32 or FieldT is cuint or FieldT is uint: FieldT(DatumGetObjectId(rawDatum))
      elif FieldT is float32 or FieldT is cfloat: FieldT(DatumGetFloat4(rawDatum))
      elif FieldT is float64 or FieldT is cdouble:
        let colOid = getTupleAttrOid(tupDesc, idx)
        if colOid == 700.Oid: FieldT(DatumGetFloat4(rawDatum))
        else: FieldT(DatumGetFloat8(rawDatum))
      elif FieldT is distinct:
        FieldT(extractField[distinctBase(FieldT)](th, tupDesc, idx, rawDatum))
      elif FieldT is string:
        getTupleStringAttr(th, tupDesc, idx)
      elif FieldT is PgText:
        if rawDatum == Datum(0): default(FieldT) else: getPgText(rawDatum)
      elif FieldT is PgBytea:
        if rawDatum == Datum(0): default(FieldT) else: getPgBytea(rawDatum)
      elif FieldT is PgUuid:
        if rawDatum == Datum(0): default(FieldT) else: getPgUuid(rawDatum)
      elif FieldT is PgDate:
        getPgDate(rawDatum)
      elif FieldT is PgTimestamp:
        getPgTimestamp(rawDatum)
      elif FieldT is PgTimestampTz:
        getPgTimestampTz(rawDatum)
      elif FieldT is PgInterval:
        if rawDatum == Datum(0): default(FieldT) else: getPgInterval(rawDatum)
      elif FieldT is PgNumeric:
        if rawDatum == Datum(0): default(FieldT) else: getPgNumeric(rawDatum)
      elif FieldT is cstring:
        {.error: "Raw 'cstring' fields in composite objects are unsafe (no memory ownership). Use 'string' (ORC-managed) or 'PgText' (zero-copy) instead.".}
      elif FieldT is char:
        DatumGetChar(rawDatum)
      elif FieldT is JsonNode:
        if rawDatum == Datum(0): newJNull()
        else: DatumToJsonNode(rawDatum)
      elif FieldT is enum:
        let colOid = getTupleAttrOid(tupDesc, idx)
        if colOid == 25.Oid:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          if cs.len > 0:
            try: parseEnum[FieldT](cs)
            except CatchableError: default(FieldT)
          else:
            default(FieldT)
        else:
          try: oidToEnum[FieldT](DatumGetObjectId(rawDatum))
          except CatchableError: default(FieldT)
      elif FieldT is seq:
        if rawDatum == Datum(0):
          result = @[]
        else:
          type ElemT = typeof(default(FieldT)[0])
          let arrPtr = htup_DatumGetArrayTypeP(rawDatum)
          if arrPtr != nil:
            var elemsPtr: ptr Datum
            var nullsPtr: ptr bool
            var nElems: cint
            let layout = arrayLayoutForElem[ElemT]()
            htup_deconstruct_array(arrPtr, layout.oid, layout.len, layout.byVal, layout.align,
                addr elemsPtr, addr nullsPtr, addr nElems)
            let elemArr = cast[ptr UncheckedArray[Datum]](elemsPtr)
            let nullArr = cast[ptr UncheckedArray[bool]](nullsPtr)
            result = newSeq[ElemT](nElems)
            for k in 0 ..< nElems:
              if nullArr == nil or not nullArr[k]:
                result[k] = unpackDatumToElem[ElemT](elemArr[k])
            if elemsPtr != nil: htup_pfree(elemsPtr)
            if nullsPtr != nil: htup_pfree(nullsPtr)
          else:
            result = @[]
      else:
        getTupleStringAttr(th, tupDesc, idx)

proc tupleHeaderToObject*[T: object | tuple](th: HeapTupleHeader): T {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if th.isNil: return default(T)
      let tupDesc = getTupleDesc(th)
      if tupDesc.isNil: return default(T)

      try:
        let descNatts = cast[TupleDescStruct](tupDesc).natts
        var idx: cint = 1
        for name, field in fieldPairs(result):
          idx = nextValidTableColumn(tupDesc, idx)
          if idx < 1 or idx > descNatts:
            when typeof(field) is Option:
              field = none(typeof(field.get))
            else:
              field = default(typeof(field))
          else:
            var isNull: bool
            let rawDatum = GetAttributeByNum(th, idx, isNull)
            if isNull:
              when typeof(field) is Option:
                field = none(typeof(field.get))
              else:
                field = default(typeof(field))
            else:
              when typeof(field) is Option:
                field = some(extractField[typeof(field.get)](th, tupDesc, idx, rawDatum))
              else:
                field = extractField[typeof(field)](th, tupDesc, idx, rawDatum)
            idx += 1
      finally:
        DecrTupleDescRefCount(tupDesc)

# -----------------------------------------------------------------------------
# High-Level Generic Serializer: object -> HeapTuple / Datum
# -----------------------------------------------------------------------------

proc packScalarDatum*[FieldT](val: FieldT, needFree: var bool): Datum {.tags: [].} =
  ## Converts a single composite field or datum element into a PostgreSQL `Datum`,
  ## reporting whether `palloc`'d memory can be safely freed immediately after `heap_form_tuple`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      needFree = false
      when FieldT is bool:
        BoolGetDatum(val)
      elif FieldT is int8:
        Int8GetDatum(val)
      elif FieldT is uint8:
        UInt8GetDatum(val)
      elif FieldT is int16 or FieldT is cshort:
        Int16GetDatum(int16(val))
      elif FieldT is uint16:
        UInt16GetDatum(val)
      elif FieldT is int32 or FieldT is cint or FieldT is int:
        Int32GetDatum(int32(val))
      elif FieldT is int64 or FieldT is clonglong:
        Int64GetDatum(int64(val))
      elif FieldT is uint64:
        UInt64GetDatum(val)
      elif FieldT is uint32 or FieldT is cuint or FieldT is uint:
        ObjectIdGetDatum(Oid(val))
      elif FieldT is float32 or FieldT is cfloat:
        Float4GetDatum(float32(val))
      elif FieldT is float64 or FieldT is cdouble:
        Float8GetDatum(float64(val))
      elif FieldT is char:
        CharGetDatum(cchar(val))
      elif FieldT is string:
        needFree = true
        CStringGetTextDatum(cstring(val))
      elif FieldT is cstring:
        needFree = true
        CStringGetTextDatum(val)
      elif FieldT is PgText:
        needFree = true
        returnPgText(val)
      elif FieldT is PgBytea:
        needFree = true
        returnPgBytea(val)
      elif FieldT is PgUuid:
        needFree = true
        returnPgUuid(val)
      elif FieldT is PgDate:
        returnPgDate(val)
      elif FieldT is PgTimestamp:
        returnPgTimestamp(val)
      elif FieldT is PgTimestampTz:
        returnPgTimestampTz(val)
      elif FieldT is PgInterval:
        needFree = true
        returnPgInterval(val)
      elif FieldT is PgNumeric:
        returnPgNumeric(val)
      elif FieldT is JsonNode:
        needFree = true
        JsonNodeToDatum(val)
      elif FieldT is enum:
        enumToDatum(val)
      elif FieldT is distinct:
        packScalarDatum(distinctBase(FieldT)(val), needFree)
      else:
        needFree = true
        CStringGetTextDatum(cstring($val))

proc htupPackSeq*[E](s: seq[E]): Datum =
  let layout = arrayLayoutForElem[E]()
  if s.len == 0:
    let arrPtr = htup_construct_array(nil, 0'i32, layout.oid, layout.len, layout.byVal, layout.align)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](basic.palloc(cuint(s.len * sizeof(Datum))))
  var needFreeElem = false
  for i in 0 ..< s.len:
    var itemFree = false
    elemsBuf[i] = packScalarDatum(s[i], itemFree)
    if itemFree:
      needFreeElem = true
  let arrPtr = htup_construct_array(cast[ptr Datum](elemsBuf), s.len.cint,
      layout.oid, layout.len, layout.byVal, layout.align)
  if needFreeElem:
    for i in 0 ..< s.len:
      if elemsBuf[i] != Datum(0):
        htup_pfree(DatumGetPointer(elemsBuf[i]))
  htup_pfree(elemsBuf)
  PointerGetDatum(cast[Pointer](arrPtr))

proc scalarTypeToPgOid[T](): Oid =
  when T is bool: 16.Oid
  elif T is int8 or T is uint8 or T is char: 18.Oid
  elif T is int16 or T is cshort or T is uint16: 21.Oid
  elif T is int32 or T is cint or T is int: 23.Oid
  elif T is int64 or T is clonglong or T is uint64: 20.Oid
  elif T is uint32 or T is cuint or T is uint: 26.Oid
  elif T is float32 or T is cfloat: 700.Oid
  elif T is float64 or T is cdouble: 701.Oid
  elif T is string or T is cstring or T is PgText: 25.Oid
  elif T is PgBytea: 17.Oid
  elif T is PgUuid: 2950.Oid
  elif T is PgDate: 1082.Oid
  elif T is PgTimestamp: 1114.Oid
  elif T is PgTimestampTz: 1184.Oid
  elif T is PgInterval: 1186.Oid
  elif T is PgNumeric: 1700.Oid
  elif T is JsonNode: 3802.Oid
  elif T is enum:
    let enumOid = pgx_lookup_type_oid(cstring(sqlTypeNameFor[T]()))
    if enumOid != 0.Oid: enumOid else: 25.Oid
  elif T is distinct:
    scalarTypeToPgOid[distinctBase(T)]()
  elif T is seq:
    type ElemT = typeof(default(T)[0])
    when ElemT is bool: 1000.Oid
    elif ElemT is int16 or ElemT is cshort or ElemT is uint16: 1005.Oid
    elif ElemT is int32 or ElemT is cint or ElemT is int: 1007.Oid
    elif ElemT is int64 or ElemT is clonglong or ElemT is uint64: 1016.Oid
    elif ElemT is float32 or ElemT is cfloat: 1021.Oid
    elif ElemT is float64 or ElemT is cdouble: 1022.Oid
    elif ElemT is PgBytea: 1001.Oid
    elif ElemT is PgDate: 1182.Oid
    elif ElemT is PgTimestamp: 1115.Oid
    elif ElemT is PgTimestampTz: 1185.Oid
    elif ElemT is PgInterval: 1187.Oid
    elif ElemT is PgNumeric: 1231.Oid
    elif ElemT is PgUuid: 2951.Oid
    elif ElemT is JsonNode: 3807.Oid
    elif ElemT is enum:
      let elemOid = pgx_lookup_type_oid(cstring(sqlTypeNameFor[ElemT]()))
      let arrOid = pgx_get_array_type_oid(elemOid)
      if arrOid != 0.Oid: arrOid else: 2287.Oid
    else: 1009.Oid
  else: 25.Oid

proc fieldExpectedPgOid[F](): Oid {.inline.} =
  when F is Option:
    scalarTypeToPgOid[typeof(default(F).get)]()
  else:
    scalarTypeToPgOid[F]()

proc buildTupleDescFor*[T: object | tuple](): TupleDesc =
  var numFields: cint = 0
  var dummy: T
  for name, val in fieldPairs(dummy):
    numFields += 1

  if numFields == 0: return nil
  let desc = CreateTemplateTupleDesc(numFields)
  var attrNum: int16 = 1
  for name, val in fieldPairs(dummy):
    let oid = fieldExpectedPgOid[typeof(val)]()
    TupleDescInitEntry(desc, attrNum, cstring(name), oid, -1'i32, 0'i32)
    attrNum += 1
  return BlessTupleDesc(desc)

{.push header: "utils/memutils.h".}
var htup_TopMemoryContext {.importc: "TopMemoryContext".}: pointer
{.pop.}

proc getCachedTupleDescFor*[T: object | tuple](): TupleDesc =
  ## Thread-safe, cached blessed TupleDesc allocated in TopMemoryContext per composite type
  ## to avoid both repeated BlessTupleDesc leaks and dangling pointers across queries.
  var cached {.global.}: TupleDesc = nil
  var rebuild = cached.isNil
  if not rebuild:
    var dummy: T
    var attrIdx: cint = 0
    for _, val in fieldPairs(dummy):
      var isEnumField = false
      when typeof(val) is enum:
        isEnumField = true
      elif typeof(val) is Option:
        when typeof(default(typeof(val)).get()) is enum:
          isEnumField = true
      elif typeof(val) is seq:
        when typeof(default(typeof(val))[0]) is enum:
          isEnumField = true
      if isEnumField:
        let attr = TupleDescAttr(cached, attrIdx)
        if attr == nil or attr.atttypid != fieldExpectedPgOid[typeof(val)]():
          rebuild = true
      attrIdx += 1
  if rebuild:
    let oldCtx = if htup_TopMemoryContext != nil: basic.MemoryContextSwitchTo(
        htup_TopMemoryContext) else: nil
    try:
      cached = buildTupleDescFor[T]()
    finally:
      if oldCtx != nil:
        discard basic.MemoryContextSwitchTo(oldCtx)
  return cached

proc objectToHeapTuple*[T: object | tuple](obj: T,
    customDesc: TupleDesc = nil): HeapTuple {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      var lookupDesc: TupleDesc = nil
      var tupDesc: TupleDesc = customDesc
      if tupDesc.isNil:
        when T is object:
          let namedOid = pgx_lookup_type_oid(cstring(sqlTypeNameFor[T]()))
          if namedOid != 0.Oid:
            lookupDesc = lookup_rowtype_tupdesc_noerror(namedOid, -1'i32, true)
            tupDesc = lookupDesc
        if tupDesc.isNil:
          tupDesc = getCachedTupleDescFor[T]()
      if tupDesc.isNil: return nil

      try:
        let descNatts = cast[TupleDescStruct](tupDesc).natts
        if descNatts <= 0: return nil
        var numFields: cint = 0
        for name, val in fieldPairs(obj):
          numFields += 1

        if numFields == 0: return nil
        var values = newSeq[Datum](descNatts)
        var nulls = newSeq[bool](descNatts)
        var freeAfterForm = newSeq[bool](descNatts)
        for k in 0 ..< descNatts:
          nulls[k] = true

        var colIdx: cint = 1
        for name, val in fieldPairs(obj):
          colIdx = nextValidTableColumn(tupDesc, colIdx)
          if colIdx >= 1 and colIdx <= descNatts:
            let slot = int(colIdx - 1)
            when typeof(val) is Option:
              if val.isNone:
                nulls[slot] = true
                values[slot] = Datum(0)
              else:
                nulls[slot] = false
                let innerVal = val.get
                when typeof(innerVal) is seq:
                  values[slot] = htupPackSeq(innerVal)
                  freeAfterForm[slot] = true
                else:
                  var needFree = false
                  values[slot] = packScalarDatum(innerVal, needFree)
                  freeAfterForm[slot] = needFree
            else:
              nulls[slot] = false
              when typeof(val) is seq:
                values[slot] = htupPackSeq(val)
                freeAfterForm[slot] = true
              else:
                var needFree = false
                values[slot] = packScalarDatum(val, needFree)
                freeAfterForm[slot] = needFree
          colIdx += 1

        let htup = heap_form_tuple(tupDesc, cast[ptr Datum](addr values[0]),
            cast[ptr bool](addr nulls[0]))
        for k in 0 ..< descNatts:
          if freeAfterForm[k] and not nulls[k] and values[k] != Datum(0):
            htup_pfree(DatumGetPointer(values[k]))
        return htup
      finally:
        if lookupDesc != nil:
          DecrTupleDescRefCount(lookupDesc)

proc objectToDatum*[T: object | tuple](obj: T,
    customDesc: TupleDesc = nil): Datum {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let htup = objectToHeapTuple[T](obj, customDesc)
      if htup.isNil: return Datum(0)
      return HeapTupleGetDatum(htup)

proc objectToDatum*[T: distinct](obj: T): Datum {.tags: [].} =
  var dummy = false
  packScalarDatum(distinctBase(T)(obj), dummy)

proc objectToDatum*[T: enum](obj: T): Datum {.tags: [].} =
  enumToDatum(obj)

proc packObjectSeq*[T: object | tuple](s: seq[T]): Datum {.tags: [].} =
  ## Packs a sequence of composite objects or tuples into a PostgreSQL record/composite array Datum.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      var elemOid = pgx_lookup_type_oid(cstring(sqlTypeNameFor[T]()))
      if elemOid == 0.Oid:
        elemOid = 2249.Oid # RECORDOID
      if s.len == 0:
        let arrPtr = htup_construct_array(nil, 0'i32, elemOid, -1'i32, false, 'd'.cchar)
        return PointerGetDatum(cast[Pointer](arrPtr))
      let elemsBuf = cast[ptr UncheckedArray[Datum]](basic.palloc(cuint(s.len * sizeof(Datum))))
      for i in 0 ..< s.len:
        elemsBuf[i] = objectToDatum(s[i])
      let arrPtr = htup_construct_array(cast[ptr Datum](elemsBuf), s.len.cint,
          elemOid, -1'i32, false, 'd'.cchar)
      htup_pfree(elemsBuf)
      return PointerGetDatum(cast[Pointer](arrPtr))
