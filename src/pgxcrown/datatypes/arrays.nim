import basic
import heaptuples
import jsonb
import std/options
export heaptuples
export options

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
proc ARR_DIMS*(arr: ptr ArrayType): ptr UncheckedArray[cint] {.importc.}
proc ARR_DATA_PTR*(arr: ptr ArrayType): pointer {.importc.}
proc ARR_HASNULL*(arr: ptr ArrayType): bool {.importc.}

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

# -----------------------------------------------------------------------------
# Zero-Copy Fast-Path Vector (PgVector[T])
# -----------------------------------------------------------------------------

type
  PgVector*[T] = object
    raw*: ptr ArrayType
    dataPtr*: ptr UncheckedArray[T]
    len*: int
    hasNulls*: bool
    nullElems*: seq[T]
    nullBitmap*: seq[bool]

template len*[T](v: PgVector[T]): int = v.len
template low*[T](v: PgVector[T]): int = 0
template high*[T](v: PgVector[T]): int = (if v.len > 0: v.len - 1 else: 0)

template `[]`*[T](v: PgVector[T], idx: int): T =
  v.dataPtr[idx]

template `[]`*[T](v: PgVector[T], slice: HSlice[int, int]): untyped =
  let sA = slice.a
  let sB = slice.b
  let subLen = if sB >= sA: sB - sA + 1 else: 0
  let subPtr = if subLen > 0 and v.dataPtr != nil: cast[ptr UncheckedArray[T]](addr v.dataPtr[sA]) else: nil
  PgVector[T](
    raw: nil,
    dataPtr: subPtr,
    len: subLen,
    hasNulls: v.hasNulls,
    nullElems: if v.hasNulls and v.nullElems.len > 0: v.nullElems[sA .. sB] else: @[],
    nullBitmap: if v.hasNulls and v.nullBitmap.len > 0: v.nullBitmap[sA .. sB] else: @[]
  )

template `[]=`*[T](v: var PgVector[T], idx: int, val: T) =
  v.dataPtr[idx] = val

iterator items*[T](v: PgVector[T]): T =
  for i in 0 ..< v.len:
    yield v.dataPtr[i]

iterator pairs*[T](v: PgVector[T]): (int, T) =
  for i in 0 ..< v.len:
    yield (i, v.dataPtr[i])

template isNull*[T](v: PgVector[T], idx: int): bool =
  if not v.hasNulls or v.nullBitmap.len == 0:
    false
  else:
    v.nullBitmap[idx]

proc get*[T](v: PgVector[T], idx: int): Option[T] =
  if v.isNull(idx):
    none(T)
  else:
    some(v.dataPtr[idx])

template toOpenArray*[T](v: PgVector[T]): untyped =
  toOpenArray(v.dataPtr, 0, v.len - 1)

template toOpenArray*[T](v: PgVector[T], first, last: int): untyped =
  toOpenArray(v.dataPtr, first, last)

template `@`*[T](v: PgVector[T]): seq[T] =
  var res = newSeq[T](v.len)
  for i in 0 ..< v.len:
    res[i] = v.dataPtr[i]
  res

converter toSeq*[T](v: PgVector[T]): seq[T] =
  @v

proc toPgVector*[T](s: seq[T]): PgVector[T] =
  if s.len == 0:
    PgVector[T](raw: nil, dataPtr: nil, len: 0, hasNulls: false)
  else:
    PgVector[T](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[T]](unsafeAddr s[0]),
      len: s.len,
      hasNulls: false,
      nullElems: s
    )

proc `$`*[T](v: PgVector[T]): string =
  result = "@["
  for i in 0 ..< v.len:
    if i > 0: result.add(", ")
    if v.isNull(i):
      result.add("null")
    else:
      result.add($v.dataPtr[i])
  result.add("]")

proc `==`*[T](a, b: PgVector[T]): bool =
  if a.len != b.len: return false
  if a.hasNulls or b.hasNulls:
    for i in 0 ..< a.len:
      if a.isNull(i) != b.isNull(i): return false
      if not a.isNull(i) and a[i] != b[i]: return false
    return true
  if a.dataPtr == b.dataPtr: return true
  for i in 0 ..< a.len:
    if a.dataPtr[i] != b.dataPtr[i]: return false
  return true

template extractPgVectorFast(arrayDatum, elemOid, elemLen, elemByVal, elemAlign, elemDatumGetter, T): untyped =
  if arrayDatum == 0:
    PgVector[T](raw: nil, dataPtr: nil, len: 0, hasNulls: false)
  else:
    let arrPtr = DatumGetArrayTypeP(arrayDatum)
    if arrPtr == nil or arrPtr.ndim == 0:
      PgVector[T](raw: arrPtr, dataPtr: nil, len: 0, hasNulls: false)
    else:
      let dims = ARR_DIMS(arrPtr)
      var nElems = dims[0].int
      for d in 1 ..< arrPtr.ndim:
        nElems *= dims[d].int

      if nElems == 0:
        PgVector[T](raw: arrPtr, dataPtr: nil, len: 0, hasNulls: false)
      elif not ARR_HASNULL(arrPtr):
        PgVector[T](
          raw: arrPtr,
          dataPtr: cast[ptr UncheckedArray[T]](ARR_DATA_PTR(arrPtr)),
          len: nElems,
          hasNulls: false
        )
      else:
        var elemsPtr: ptr Datum
        var nullsPtr: ptr bool
        var extractedElems: cint
        deconstruct_array(arrPtr, elemOid, elemLen, elemByVal, elemAlign, addr elemsPtr, addr nullsPtr, addr extractedElems)
        let elemArray = cast[ptr UncheckedArray[Datum]](elemsPtr)
        let nullArray = cast[ptr UncheckedArray[bool]](nullsPtr)

        var nullElems = newSeq[T](extractedElems)
        var nullBitmap = newSeq[bool](extractedElems)
        for i in 0 ..< extractedElems:
          let isNull = (nullArray != nil and nullArray[i])
          nullBitmap[i] = isNull
          if not isNull:
            nullElems[i] = elemDatumGetter(elemArray[i])
          else:
            nullElems[i] = default(T)

        if elemsPtr != nil: pfree(elemsPtr)
        if nullsPtr != nil: pfree(nullsPtr)

        let ptrData = if nullElems.len > 0: cast[ptr UncheckedArray[T]](addr nullElems[0]) else: nil
        PgVector[T](
          raw: arrPtr,
          dataPtr: ptrData,
          len: extractedElems.int,
          hasNulls: true,
          nullElems: nullElems,
          nullBitmap: nullBitmap
        )

proc getPgVectorFloat64*(arrayDatum: Datum): PgVector[float64] =
  extractPgVectorFast(arrayDatum, FLOAT8OID, 8'i32, true, 'd'.cchar, DatumGetFloat8, float64)

proc getPgVectorFloat32*(arrayDatum: Datum): PgVector[float32] =
  extractPgVectorFast(arrayDatum, FLOAT4OID, 4'i32, true, 'i'.cchar, (proc(d: Datum): float32 = DatumGetFloat4(d).float32), float32)

proc getPgVectorInt32*(arrayDatum: Datum): PgVector[int32] =
  extractPgVectorFast(arrayDatum, INT4OID, 4'i32, true, 'i'.cchar, DatumGetInt32, int32)

proc getPgVectorInt64*(arrayDatum: Datum): PgVector[int64] =
  extractPgVectorFast(arrayDatum, INT8OID, 8'i32, true, 'd'.cchar, DatumGetInt64, int64)

proc getPgVectorInt16*(arrayDatum: Datum): PgVector[int16] =
  extractPgVectorFast(arrayDatum, INT2OID, 2'i32, true, 's'.cchar, DatumGetInt16, int16)

proc getPgVectorBool*(arrayDatum: Datum): PgVector[bool] =
  extractPgVectorFast(arrayDatum, BOOLOID, 1'i32, true, 'c'.cchar, (proc(d: Datum): bool = d != 0'u64), bool)

proc returnPgVectorFloat64*(v: PgVector[float64]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, FLOAT8OID, 8'i32, true, 'd'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = Float8GetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, FLOAT8OID, 8'i32, true, 'd'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnPgVectorFloat32*(v: PgVector[float32]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, FLOAT4OID, 4'i32, true, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = Float4GetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, FLOAT4OID, 4'i32, true, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnPgVectorInt32*(v: PgVector[int32]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT4OID, 4'i32, true, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = Int32GetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, INT4OID, 4'i32, true, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnPgVectorInt64*(v: PgVector[int64]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT8OID, 8'i32, true, 'd'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = Int64GetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, INT8OID, 8'i32, true, 'd'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnPgVectorInt16*(v: PgVector[int16]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT2OID, 2'i32, true, 's'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = Int16GetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, INT2OID, 2'i32, true, 's'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnPgVectorBool*(v: PgVector[bool]): Datum =
  if v.raw != nil and not v.hasNulls:
    return PointerGetDatum(cast[Pointer](v.raw))
  if v.len == 0:
    let arrPtr = construct_array(nil, 0'i32, BOOLOID, 1'i32, true, 'c'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))
  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(v.len * sizeof(Datum))))
  for i in 0 ..< v.len:
    elemsBuf[i] = BoolGetDatum(v[i])
  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), v.len.cint, BOOLOID, 1'i32, true, 'c'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

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

proc returnArrayFloat32*(s: seq[float32]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, FLOAT4OID, 4'i32, true, 'i'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = Float4GetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, FLOAT4OID, 4'i32, true, 'i'.cchar)
  pfree(elemsBuf)
  return PointerGetDatum(cast[Pointer](arrPtr))

proc returnArrayInt16*(s: seq[int16]): Datum =
  if s.len == 0:
    let arrPtr = construct_array(nil, 0'i32, INT2OID, 2'i32, true, 's'.cchar)
    return PointerGetDatum(cast[Pointer](arrPtr))

  let elemsBuf = cast[ptr UncheckedArray[Datum]](palloc(cuint(s.len * sizeof(Datum))))
  for i in 0 ..< s.len:
    elemsBuf[i] = Int16GetDatum(s[i])

  let arrPtr = construct_array(cast[ptr Datum](elemsBuf), s.len.cint, INT2OID, 2'i32, true, 's'.cchar)
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

proc returnPgVectorFloat64*(s: seq[float64]): Datum {.inline.} = returnArrayFloat64(s)
proc returnPgVectorFloat32*(s: seq[float32]): Datum {.inline.} = returnArrayFloat32(s)
proc returnPgVectorInt32*(s: seq[int32]): Datum {.inline.} = returnArrayInt32(s)
proc returnPgVectorInt64*(s: seq[int64]): Datum {.inline.} = returnArrayInt64(s)
proc returnPgVectorInt16*(s: seq[int16]): Datum {.inline.} = returnArrayInt16(s)
proc returnPgVectorBool*(s: seq[bool]): Datum {.inline.} = returnArrayBool(s)

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

proc seqTupleHeaderToObjects*[T: object | tuple](arrayDatum: Datum): seq[T] =
  let thSeq = getArrayHeapTuples(arrayDatum)
  result = newSeq[T](thSeq.len)
  for i in 0 ..< thSeq.len:
    result[i] = tupleHeaderToObject[T](thSeq[i])
