import basic
import heaptuples
export heaptuples

{.push header: "postgres.h".}
proc pfree*(p: pointer) {.importc: "pfree".}
{.pop.}

{.push header: "utils/array.h".}

type
  ArrayType* {.importc.} = object
    ndim*: cint
    dataoffset*: int32
    elemtype*: Oid

proc DatumGetArrayTypeP*(x: Datum): ptr ArrayType {.importc.}

proc deconstruct_array*(
  arr: ptr ArrayType,
  elmtype: Oid,
  elmlen: cint,
  elmbyval: bool,
  elmalign: cchar,
  elemsp: ptr ptr Datum,
  nullsp: ptr ptr bool,
  nelemsp: ptr cint
) {.importc.}

proc construct_array*(
  elems: ptr Datum,
  nelems: cint,
  elmtype: Oid,
  elmlen: cint,
  elmbyval: bool,
  elmalign: cchar
): ptr ArrayType {.importc.}

{.pop.}

# Type OIDs for PostgreSQL primitive types
const
  BOOLOID*: Oid = 16
  INT8OID*: Oid = 20
  INT2OID*: Oid = 21
  INT4OID*: Oid = 23
  TEXTOID*: Oid = 25
  FLOAT4OID*: Oid = 700
  FLOAT8OID*: Oid = 701
  JSONBOID*: Oid = 3802
  RECORDOID*: Oid = 2249

proc getArrayHeapTuples*(arrayDatum: Datum): seq[HeapTupleHeader] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, RECORDOID, -1'i32, false, 'd'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[HeapTupleHeader](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = nil
    else:
      result[i] = cast[HeapTupleHeader](elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

# -----------------------------------------------------------------------------
# Unpacking PostgreSQL SQL Arrays (Datum -> seq[T])
# -----------------------------------------------------------------------------

proc getArrayInt32*(arrayDatum: Datum): seq[int32] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, INT4OID, 4'i32, true, 'i'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[int32](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = 0'i32
    else:
      result[i] = DatumGetInt32(elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

proc getArrayInt64*(arrayDatum: Datum): seq[int64] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, INT8OID, 8'i32, true, 'd'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[int64](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = 0'i64
    else:
      result[i] = DatumGetInt64(elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

proc getArrayFloat64*(arrayDatum: Datum): seq[float64] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, FLOAT8OID, 8'i32, true, 'd'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[float64](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = 0.0
    else:
      result[i] = DatumGetFloat8(elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

proc getArrayBool*(arrayDatum: Datum): seq[bool] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, BOOLOID, 1'i32, true, 'c'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[bool](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = false
    else:
      result[i] = (elemArray[i] != 0'u64)

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

proc getArrayString*(arrayDatum: Datum): seq[string] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, TEXTOID, -1'i32, false, 'i'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[string](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = ""
    else:
      result[i] = $TextDatumGetCString(elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)


# -----------------------------------------------------------------------------
# Packing Nim Sequences into PostgreSQL SQL Arrays (seq[T] -> Datum)
# -----------------------------------------------------------------------------

proc returnArrayInt32*(s: seq[int32]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT4OID, 4'i32, true, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = Int32GetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, INT4OID, 4'i32, true, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnArrayInt64*(s: seq[int64]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT8OID, 8'i32, true, 'd'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = Int64GetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, INT8OID, 8'i32, true, 'd'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnArrayFloat64*(s: seq[float64]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, FLOAT8OID, 8'i32, true, 'd'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = Float8GetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, FLOAT8OID, 8'i32, true, 'd'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnArrayBool*(s: seq[bool]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, BOOLOID, 1'i32, true, 'c'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = BoolGetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, BOOLOID, 1'i32, true, 'c'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnArrayString*(s: seq[string]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, TEXTOID, -1'i32, false, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = CStringGetTextDatum(cstring(s[i]))

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, TEXTOID, -1'i32, false, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc getArrayJsonNode*(arrayDatum: Datum): seq[JsonNode] =
  if arrayDatum == 0: return @[]
  let arrPtr = DatumGetArrayTypeP(arrayDatum)
  if arrPtr == nil: return @[]

  var elemsPtr: ptr Datum
  var nullsPtr: ptr bool
  var nElems: cint

  deconstruct_array(arrPtr, JSONBOID, -1'i32, false, 'i'.cchar, addr elemsPtr, addr nullsPtr, addr nElems)

  let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
  let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

  result = newSeq[JsonNode](nElems)
  for i in 0 ..< nElems:
    if nullArray != nil and nullArray[i]:
      result[i] = newJNull()
    else:
      result[i] = DatumToJsonNode(elemArray[i])

  if elemsPtr != nil: pfree(elemsPtr)
  if nullsPtr != nil: pfree(nullsPtr)

proc returnArrayJsonNode*(s: seq[JsonNode]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, JSONBOID, -1'i32, false, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = JsonNodeToDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, JSONBOID, -1'i32, false, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc seqTupleHeaderToObjects*[T: object](arrayDatum: Datum): seq[T] =
  let thSeq = getArrayHeapTuples(arrayDatum)
  result = newSeq[T](thSeq.len)
  for i in 0 ..< thSeq.len:
    result[i] = tupleHeaderToObject[T](thSeq[i])
