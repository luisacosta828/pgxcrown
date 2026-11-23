## =============================================================================
## PostgreSQL Server Programming Interface (SPI) Bridge & High-Level Row Consumer.
## Provides binary SPI datum deserialization, real $1..$N parameter binding,
## cached TupleDesc/field mapping, prepared plans, streaming cursors,
## non-atomic procedure transactions, and strongly-typed row consumers.
## =============================================================================

import std/[tables, options, strutils, json, typetraits, os]
export json, tables
from datatypes/basic import Datum, NullDatum, PDatum, POid, NameData, Name,
  Oid, Pointer, oidvector, palloc, safePfree, NameStr,
  DatumGetObjectId, DatumGetInt64, DatumGetInt32, DatumGetInt16, DatumGetInt8,
  DatumGetUInt8, DatumGetChar, DatumGetBool, DatumGetFloat4, DatumGetFloat8,
  DatumGetCString, DatumGetName,
  ObjectIdGetDatum, Int64GetDatum, Int32GetDatum, Int16GetDatum,
  BoolGetDatum, Float4GetDatum, Float8GetDatum,
  OidOutputFunctionCall, getTypeOutputInfo
from datatypes/heaptuples import HeapTuple, TupleDesc, oidToEnum,
  DatumGetHeapTupleHeader, tupleHeaderToObject
from datatypes/strings import PgText, initPgText, returnPgText
from datatypes/bytea import PgBytea, initPgBytea, fromHexBytea, returnPgBytea
from datatypes/uuid import PgUuid, nilUuid, parsePgUuid, getPgUuid, returnPgUuid
from datatypes/temporal import PgDate, PgTimestamp, PgTimestampTz, PgInterval,
  parsePgDate, parsePgTimestamp, parsePgTimestampTz, parsePgInterval,
  getPgDate, getPgTimestamp, getPgTimestampTz, getPgInterval,
  returnPgDate, returnPgTimestamp, returnPgTimestampTz, returnPgInterval
from datatypes/numeric import PgNumeric, initPgNumericZero, pgNumeric, returnPgNumeric
from datatypes/jsonb import DatumToJsonNode, JsonNodeToDatum
from datatypes/arrays import BOOLOID, BYTEAOID, INT8OID, INT2OID, INT4OID,
  TEXTOID, FLOAT4OID, FLOAT8OID, DATEOID, TIMESTAMPOID, TIMESTAMPTZOID,
  INTERVALOID, NUMERICOID, UUIDOID, JSONBOID, RECORDOID,
  DatumGetArrayTypeP, deconstruct_array,
  returnArrayString, returnArrayInt32, returnArrayInt64, returnArrayFloat64, returnArrayBool
export HeapTuple, TupleDesc
export BOOLOID, BYTEAOID, INT8OID, INT2OID, INT4OID,
  TEXTOID, FLOAT4OID, FLOAT8OID, DATEOID, TIMESTAMPOID, TIMESTAMPTZOID,
  INTERVALOID, NUMERICOID, UUIDOID, JSONBOID, RECORDOID
import query_builder
import reports/reports
export reports
import ./memcontext

const PgxSpiCHeadersDir = currentSourcePath.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxSpiCHeadersDir).}

const
  CHAROID*: Oid = 18.Oid
  NAMEOID*: Oid = 19.Oid
  OIDOID*: Oid = 26.Oid
  JSONOID*: Oid = 114.Oid
  UNKNOWNOID*: Oid = 705.Oid
  BPCHAROID*: Oid = 1042.Oid
  VARCHAROID*: Oid = 1043.Oid
  CSTRINGOID*: Oid = 2275.Oid

  BOOLARRAYOID*: Oid = 1000.Oid
  BYTEAARRAYOID*: Oid = 1001.Oid
  INT2ARRAYOID*: Oid = 1005.Oid
  INT4ARRAYOID*: Oid = 1007.Oid
  TEXTARRAYOID*: Oid = 1009.Oid
  INT8ARRAYOID*: Oid = 1016.Oid
  FLOAT4ARRAYOID*: Oid = 1021.Oid
  FLOAT8ARRAYOID*: Oid = 1022.Oid
  OIDARRAYOID*: Oid = 1028.Oid
  JSONARRAYOID*: Oid = 199.Oid
  BPCHARARRAYOID*: Oid = 1014.Oid
  VARCHARARRAYOID*: Oid = 1015.Oid
  DATEARRAYOID*: Oid = 1182.Oid
  TIMESTAMPARRAYOID*: Oid = 1115.Oid
  TIMESTAMPTZARRAYOID*: Oid = 1185.Oid
  INTERVALARRAYOID*: Oid = 1187.Oid
  NUMERICARRAYOID*: Oid = 1231.Oid
  UUIDARRAYOID*: Oid = 2951.Oid
  JSONBARRAYOID*: Oid = 3807.Oid

type
  DbReadEffect* = object of RootEffect
  DbWriteEffect* = object of RootEffect

  const_string* {.importc: "const char*".} = cstring

  Column* = Table[string, string]
  Row* = seq[Column]
  ResultSet* = seq[Row]

  TupleTable* {.importc: "SPITupleTable*", header: "executor/spi.h".} = pointer
  SPIPlanPtr* {.importc: "SPIPlanPtr", header: "executor/spi.h".} = pointer
  Portal* {.importc: "Portal", header: "executor/spi.h".} = pointer

  SpiColMeta* = object
    attnum*: cint
    name*: string
    typid*: Oid

  SpiFieldBinding = object
    attnum: cint
    typid: Oid

  SpiPlan* = object
    raw*: SPIPlanPtr
    nargs*: int
    kept*: bool

  SpiCursor* = object
    portal*: Portal
    name*: string
    closed*: bool
    ownsSpiConn*: bool
    outerCtx*: pointer

  SpiOK* {.pure.} = enum
    CONNECT = 1,
    FINISH, FETCH, UTILITY,
    SELECT, SELINTO, INSERT,
    DELETE, UPDATE, CURSOR
    INSERT_RETURNING, DELETE_RETURNING, UPDATE_RETURNING,
    REWRITTEN, REL_REGISTER, REL_UNREGISTER, TD_REGISTER

  SpiError* {.pure, size: sizeof(cint).} = enum
    REL_NOT_FOUND = -13,
    REL_DUPLICATE,
    TYPUNKNOWN,
    NOOUTFUNC,
    NOATTRIBUTE,
    TRANSACTION,
    PARAM,
    ARGUMENT,
    CURSOR,
    UNCONNECTED,
    OPUNKNOWN,
    COPY,
    CONNECT

{.push header: "pgx_types.h".}
proc pgxMarkDbRead*() {.importc: "pgx_noop_effect", tags: [DbReadEffect].}
proc pgxMarkDbWrite*() {.importc: "pgx_noop_effect", tags: [DbWriteEffect].}
proc pgxDatumGetNumeric(d: Datum): pointer {.importc: "pgx_datum_get_numeric".}
proc pgxNumericOut(n: pointer): cstring {.importc: "pgx_numeric_out".}
proc pgxNumericToInt64(n: pointer): int64 {.importc: "pgx_numeric_to_int64".}
proc pgxNumericToFloat8(n: pointer): float64 {.importc: "pgx_numeric_to_float8".}
{.pop.}

{.push header: "utils/lsyscache.h".}
proc getTyplenbyvalalign(typid: Oid, typlen: ptr int16, typbyval: ptr bool, typalign: ptr char) {.importc: "get_typlenbyvalalign".}
{.pop.}

{.push header: "executor/spi.h".}
proc connect*(): cint {.importc: "SPI_connect".}
proc connectExt*(options: cint): cint {.importc: "SPI_connect_ext".}
proc finish*(): cint {.importc: "SPI_finish".}
proc exec*(c: const_string, count: clong): cint {.importc: "SPI_exec".}
proc execute*(c: const_string, read_only: bool,
    count: clong): cint {.importc: "SPI_execute".}
proc execute_with_args*(c: const_string, nargs: cint, argtypes: POid, values: PDatum, Nulls: const_string,
                        read_only: bool,
                        count: clong): cint {.importc: "SPI_execute_with_args".}
proc spiPrepareRaw*(src: const_string, nargs: cint, argtypes: POid): SPIPlanPtr {.importc: "SPI_prepare".}
proc spiKeepplanRaw*(plan: SPIPlanPtr): cint {.importc: "SPI_keepplan".}
proc spiFreeplanRaw*(plan: SPIPlanPtr): cint {.importc: "SPI_freeplan".}
proc spiExecutePlanRaw*(plan: SPIPlanPtr, values: PDatum, nulls: const_string,
                        read_only: bool, count: clong): cint {.importc: "SPI_execute_plan".}
proc spiCursorFetchRaw*(portal: Portal, forward: bool, count: clong) {.importc: "SPI_cursor_fetch".}
proc spiCursorCloseRaw*(portal: Portal) {.importc: "SPI_cursor_close".}
proc spiCommitRaw*() {.importc: "SPI_commit".}
proc spiCommitAndChainRaw*() {.importc: "SPI_commit_and_chain".}
proc spiRollbackRaw*() {.importc: "SPI_rollback".}
proc spiRollbackAndChainRaw*() {.importc: "SPI_rollback_and_chain".}
proc fname*(tupdesc: TupleDesc, fnumber: cint): const_string {.importc: "SPI_fname".}
proc gettype*(tupdesc: TupleDesc, fnumber: cint): const_string {.importc: "SPI_gettype".}
proc getvalue*(tupl: HeapTuple, tupdesc: TupleDesc,
    fnumber: cint): const_string {.importc: "SPI_getvalue".}
proc result_code_string*(code: cint): const_string {.importc: "SPI_result_code_string".}
{.pop.}

{.push header: "pgx_spi.h".}
proc getTupdescRaw(tuptable: TupleTable): TupleDesc {.importc: "pgx_spi_get_tupdesc".}
proc getNattsRaw(tupdesc: TupleDesc): cint {.importc: "pgx_spi_get_natts".}
proc getTupleRaw(tuptable: TupleTable, idx: uint64): HeapTuple {.importc: "pgx_spi_get_tuple".}
proc pgxSpiAttname*(tupdesc: TupleDesc, attnum: cint): const_string {.importc: "pgx_spi_attname".}
proc pgxSpiAtttypid*(tupdesc: TupleDesc, attnum: cint): Oid {.importc: "pgx_spi_atttypid".}
proc pgxSpiAttisdropped*(tupdesc: TupleDesc, attnum: cint): bool {.importc: "pgx_spi_attisdropped".}
proc pgxSpiGetbinval*(tupl: HeapTuple, tupdesc: TupleDesc, attnum: cint, isnull: ptr bool): Datum {.importc: "pgx_spi_getbinval".}
proc pgxSpiNonAtomicOpt*(): cint {.importc: "pgx_spi_non_atomic_opt".}
proc pgxSpiEffectiveReadOnly*(queryReadOnly: bool): bool {.importc: "pgx_spi_effective_readonly".}
proc pgxSpiGetResult*(): cint {.importc: "pgx_spi_get_result".}
proc pgxSpiExecute*(src: const_string, readOnly: bool, count: clong): cint {.importc: "pgx_spi_execute".}
proc pgxSpiExecuteWithArgs*(src: const_string, nargs: cint, argtypes: POid, values: PDatum,
                            nulls: const_string, readOnly: bool, count: clong): cint {.importc: "pgx_spi_execute_with_args".}
proc pgxSpiExecutePlan*(plan: SPIPlanPtr, values: PDatum, nulls: const_string,
                        readOnly: bool, count: clong): cint {.importc: "pgx_spi_execute_plan".}
proc pgxSpiCursorOpenWithArgs*(name: const_string, src: const_string, nargs: cint, argtypes: POid,
                               values: PDatum, nulls: const_string, readOnly: bool,
                               cursorOptions: cint): Portal {.importc: "pgx_spi_cursor_open_with_args".}
proc pgxSpiFreetuptableIfSet*() {.importc: "pgx_spi_freetuptable_if_set".}
proc pgxSpiDetoastPacked*(d: Datum): pointer {.importc: "pgx_spi_detoast_packed".}
proc pgxSpiVarlenaLen*(p: pointer): csize_t {.importc: "pgx_spi_varlena_len".}
proc pgxSpiVarlenaData*(p: pointer): const_string {.importc: "pgx_spi_varlena_data".}
proc pgxSpiIsDetoastedCopy*(orig: Datum, detoasted: pointer): bool {.importc: "pgx_spi_is_detoasted_copy".}
{.pop.}

proc getTupdesc*(tuptable: TupleTable): TupleDesc = getTupdescRaw(tuptable)
proc getNatts*(tupdesc: TupleDesc): cint = getNattsRaw(tupdesc)
proc getTuple*(tuptable: TupleTable, idx: uint64): HeapTuple = getTupleRaw(
    tuptable, idx)

# =============================================================================
# Type Converters & Row Mapper (Text Fallback + Binary Zero-Text Extraction)
# =============================================================================

proc parsePgArray*(val: string): seq[string] =
  ## Parses a PostgreSQL string array representation (e.g. '{a,b,c}' or '{"a,b","c"}') into elements
  result = @[]
  let s = val.strip()
  if s.len < 2 or s[0] != '{' or s[^1] != '}':
    return result
  let inner = s[1 .. ^2].strip()
  if inner.len == 0:
    return result
  var cur = ""
  var inQuote = false
  var escaped = false
  for c in inner:
    if escaped:
      cur.add(c)
      escaped = false
    elif c == '\\':
      escaped = true
    elif c == '"':
      inQuote = not inQuote
    elif c == ',' and not inQuote:
      result.add(cur)
      cur = ""
    else:
      cur.add(c)
  result.add(cur)

proc parseValue*[T](val: string): T {.tags: [].} =
  ## Safely parses a string column into a strongly typed Nim value
  when isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum (or container of Datum) cannot be parsed from SPI text rows; use a concrete Nim type instead.".}
  elif T is int:
    try: parseInt(val) except CatchableError: 0
  elif T is int32:
    try: int32(parseInt(val)) except CatchableError: 0'i32
  elif T is int16:
    try: int16(parseInt(val)) except CatchableError: 0'i16
  elif T is int8:
    try: int8(parseInt(val)) except CatchableError: 0'i8
  elif T is uint:
    try: uint(parseUInt(val)) except CatchableError: 0'u
  elif T is uint64:
    try: parseBiggestUInt(val) except CatchableError: 0'u64
  elif T is uint32:
    try: uint32(parseUInt(val)) except CatchableError: 0'u32
  elif T is uint16:
    try: uint16(parseUInt(val)) except CatchableError: 0'u16
  elif T is uint8 or T is byte:
    try: uint8(parseUInt(val)) except CatchableError: 0'u8
  elif T is int64:
    try: int64(parseBiggestInt(val)) except CatchableError: 0'i64
  elif T is float:
    try: parseFloat(val) except CatchableError: 0.0
  elif T is float64:
    try: parseFloat(val) except CatchableError: 0.0
  elif T is float32:
    try: float32(parseFloat(val)) except CatchableError: 0.0'f32
  elif T is bool:
    val == "t" or val == "true" or val == "1" or val == "TRUE"
  elif T is string:
    val
  elif T is cstring:
    {.error: "Raw 'cstring' fields in SPI row mapping are unsafe (no memory ownership). Use 'string' instead.".}
  elif T is char:
    if val.len > 0: val[0] else: '\0'
  elif T is JsonNode:
    {.cast(tags: []).}:
      if val.len == 0: newJNull()
      else: (try: parseJson(val) except CatchableError: newJNull())
  elif T is enum:
    try: parseEnum[T](val) except CatchableError: default(T)
  elif T is PgUuid:
    try: parsePgUuid(val) except CatchableError: nilUuid()
  elif T is PgBytea:
    try: fromHexBytea(val) except CatchableError: initPgBytea()
  elif T is PgDate:
    try: parsePgDate(val) except CatchableError: PgDate()
  elif T is PgTimestamp:
    try: parsePgTimestamp(val) except CatchableError: PgTimestamp()
  elif T is PgTimestampTz:
    try: parsePgTimestampTz(val) except CatchableError: PgTimestampTz()
  elif T is PgInterval:
    try: parsePgInterval(val) except CatchableError: PgInterval()
  elif T is PgNumeric:
    try: pgNumeric(val) except CatchableError: initPgNumericZero()
  elif T is distinct:
    T(parseValue[distinctBase(T)](val))
  elif T is seq:
    if val.len == 0 or val == "{}":
      @[]
    else:
      var items: T = @[]
      for elem in parsePgArray(val):
        items.add(parseValue[typeof(default(T)[0])](elem))
      items
  elif T is Option:
    if val.len == 0:
      none(typeof(default(T).get))
    else:
      some(parseValue[typeof(default(T).get)](val))
  else:
    default(T)

proc mapRowTo*[T: object](row: Table[string, string]): T {.tags: [].} =
  ## Maps a SPI row Table into a strongly typed Nim object via field reflection
  for name, value in fieldPairs(result):
    if row.hasKey(name):
      value = parseValue[typeof(value)](row[name])

# Binary varlena, numeric, and array layout helpers
proc extractDirectText(d: Datum): string {.tags: [].} =
  let detoasted = pgxSpiDetoastPacked(d)
  if detoasted == nil:
    return ""
  let n = int(pgxSpiVarlenaLen(detoasted))
  let data = pgxSpiVarlenaData(detoasted)
  if n > 0 and data != nil:
    result = newString(n)
    copyMem(addr result[0], cast[pointer](data), n)
  else:
    result = ""
  if pgxSpiIsDetoastedCopy(d, detoasted):
    safePfree(detoasted)

proc isTextOid(typid: Oid): bool {.inline, tags: [].} =
  typid == TEXTOID or typid == VARCHAROID or typid == BPCHAROID

proc isTextOrJsonOid(typid: Oid): bool {.inline, tags: [].} =
  isTextOid(typid) or typid == JSONOID

proc isDetoastedPtr(d: Datum, p: pointer): bool {.inline, tags: [].} =
  p != nil and uint64(d) != cast[uint64](cast[uint](p))

proc extractFallbackString(d: Datum, typid: Oid): string {.tags: [].} =
  if isTextOrJsonOid(typid):
    return extractDirectText(d)
  if typid == CSTRINGOID:
    let cs = DatumGetCString(d)
    return if cs == nil: "" else: $cs
  if typid == NAMEOID:
    let nm = DatumGetName(d)
    return if nm == nil: "" else: $NameStr(nm[])
  if typid == 0.Oid:
    return ""
  var outFunc: Oid = 0.Oid
  var isVarlena = false
  {.cast(tags: []).}:
    getTypeOutputInfo(typid, addr outFunc, addr isVarlena)
    if outFunc != 0.Oid:
      let cs = OidOutputFunctionCall(outFunc, d)
      if cs != nil:
        result = $cs
        safePfree(cast[pointer](cs))
        return result
  return ""

proc extractNumericOut(d: Datum): string {.tags: [].} =
  let numPtr = pgxDatumGetNumeric(d)
  if numPtr == nil:
    return "0"
  let cs = pgxNumericOut(numPtr)
  result = if cs != nil: $cs else: "0"
  if cs != nil:
    safePfree(cast[pointer](cs))
  if isDetoastedPtr(d, numPtr):
    safePfree(numPtr)

proc extractInt64(d: Datum, typid: Oid): int64 {.tags: [].} =
  case typid
  of INT2OID: int64(DatumGetInt16(d))
  of INT4OID: int64(DatumGetInt32(d))
  of INT8OID: DatumGetInt64(d)
  of OIDOID: int64(DatumGetObjectId(d))
  of BOOLOID: (if DatumGetBool(d): 1'i64 else: 0'i64)
  of CHAROID: int64(DatumGetInt8(d))
  of FLOAT4OID: int64(DatumGetFloat4(d))
  of FLOAT8OID: int64(DatumGetFloat8(d))
  of NUMERICOID:
    let np = pgxDatumGetNumeric(d)
    if np == nil:
      return 0'i64
    let r = pgxNumericToInt64(np)
    if isDetoastedPtr(d, np):
      safePfree(np)
    r
  else:
    parseBiggestInt(extractFallbackString(d, typid).strip())

proc extractUInt64(d: Datum, typid: Oid): uint64 {.tags: [].} =
  case typid
  of OIDOID: uint64(DatumGetObjectId(d))
  of INT2OID:
    let v = int64(DatumGetInt16(d))
    if v < 0: raise newException(ValueError, "Negative int2 value " & $v & " cannot convert to unsigned integer")
    uint64(v)
  of INT4OID:
    let v = int64(DatumGetInt32(d))
    if v < 0: raise newException(ValueError, "Negative int4 value " & $v & " cannot convert to unsigned integer")
    uint64(v)
  of INT8OID:
    let v = DatumGetInt64(d)
    if v < 0: raise newException(ValueError, "Negative int8 value " & $v & " cannot convert to unsigned integer")
    uint64(v)
  of BOOLOID: (if DatumGetBool(d): 1'u64 else: 0'u64)
  of CHAROID: uint64(DatumGetUInt8(d))
  of NUMERICOID:
    parseBiggestUInt(extractNumericOut(d).strip())
  else:
    parseBiggestUInt(extractFallbackString(d, typid).strip())

proc getElemTypeLayout(elemOid: Oid, typlen: var int16, typbyval: var bool, typalign: var char) {.tags: [].} =
  case elemOid
  of BOOLOID, CHAROID:
    typlen = 1'i16; typbyval = true; typalign = 'c'
  of INT2OID:
    typlen = 2'i16; typbyval = true; typalign = 's'
  of INT4OID, OIDOID, DATEOID, FLOAT4OID:
    typlen = 4'i16; typbyval = true; typalign = 'i'
  of INT8OID, FLOAT8OID, TIMESTAMPOID, TIMESTAMPTZOID:
    typlen = 8'i16; typbyval = true; typalign = 'd'
  of UUIDOID:
    typlen = 16'i16; typbyval = false; typalign = 'c'
  of INTERVALOID:
    typlen = 16'i16; typbyval = false; typalign = 'd'
  of TEXTOID, VARCHAROID, BPCHAROID, BYTEAOID, NUMERICOID, JSONOID, JSONBOID:
    typlen = -1'i16; typbyval = false; typalign = 'i'
  of RECORDOID:
    typlen = -1'i16; typbyval = false; typalign = 'd'
  else:
    {.cast(tags: []).}:
      getTyplenbyvalalign(elemOid, addr typlen, addr typbyval, addr typalign)

proc datumToNim*[T](d: Datum, typid: Oid, isnull: bool): T {.tags: [].} =
  ## Deserializes a PostgreSQL binary Datum directly into Nim type T using `typid` and real `isnull`.
  mixin pgxFromDatum
  when isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum (or container of Datum) cannot be deserialized from SPI; use a concrete Nim type instead.".}
  elif T is cstring:
    {.error: "Raw 'cstring' fields in SPI row mapping are unsafe (no memory ownership). Use 'string' instead.".}
  elif T is Option:
    type ElemT = typeof(default(T).get)
    if isnull:
      return none(ElemT)
    return some(datumToNim[ElemT](d, typid, false))
  elif compiles(pgxFromDatum(d, default(T).typeof)):
    if isnull:
      return default(T)
    {.cast(tags: []).}:
      return pgxFromDatum(d, default(T).typeof)
  elif compiles(pgxFromDatum(default(T).typeof, d)):
    if isnull:
      return default(T)
    {.cast(tags: []).}:
      return pgxFromDatum(default(T).typeof, d)
  elif T is distinct:
    return T(datumToNim[distinctBase(T)](d, typid, isnull))
  else:
    if isnull:
      when T is JsonNode:
        return newJNull()
      elif T is PgNumeric:
        return initPgNumericZero()
      elif T is PgUuid:
        return nilUuid()
      elif T is PgBytea:
        return initPgBytea()
      elif T is PgText:
        return initPgText()
      else:
        return default(T)

    when T is int:
      let v = extractInt64(d, typid)
      when sizeof(int) < 8:
        if v < int64(low(int)) or v > int64(high(int)):
          raise newException(ValueError, "Integer value " & $v & " out of range for int")
      int(v)
    elif T is int64:
      extractInt64(d, typid)
    elif T is int32:
      let v = extractInt64(d, typid)
      if v < int64(low(int32)) or v > int64(high(int32)):
        raise newException(ValueError, "Integer value " & $v & " out of range for int32")
      int32(v)
    elif T is int16:
      let v = extractInt64(d, typid)
      if v < int64(low(int16)) or v > int64(high(int16)):
        raise newException(ValueError, "Integer value " & $v & " out of range for int16")
      int16(v)
    elif T is int8:
      let v = extractInt64(d, typid)
      if v < int64(low(int8)) or v > int64(high(int8)):
        raise newException(ValueError, "Integer value " & $v & " out of range for int8")
      int8(v)
    elif T is uint:
      let v = extractUInt64(d, typid)
      when sizeof(uint) < 8:
        if v > uint64(high(uint)):
          raise newException(ValueError, "Unsigned integer value " & $v & " out of range for uint")
      uint(v)
    elif T is uint64:
      extractUInt64(d, typid)
    elif T is uint32:
      let v = extractUInt64(d, typid)
      if v > uint64(high(uint32)):
        raise newException(ValueError, "Unsigned integer value " & $v & " out of range for uint32")
      uint32(v)
    elif T is uint16:
      let v = extractUInt64(d, typid)
      if v > uint64(high(uint16)):
        raise newException(ValueError, "Unsigned integer value " & $v & " out of range for uint16")
      uint16(v)
    elif T is uint8 or T is byte:
      let v = extractUInt64(d, typid)
      if v > uint64(high(uint8)):
        raise newException(ValueError, "Unsigned integer value " & $v & " out of range for uint8")
      uint8(v)
    elif T is float or T is float64:
      case typid
      of FLOAT8OID: DatumGetFloat8(d)
      of FLOAT4OID: float64(DatumGetFloat4(d))
      of INT2OID, INT4OID, INT8OID, OIDOID: float64(extractInt64(d, typid))
      of NUMERICOID:
        let np = pgxDatumGetNumeric(d)
        if np == nil: 0.0
        else:
          let r = pgxNumericToFloat8(np)
          if isDetoastedPtr(d, np): safePfree(np)
          r
      else:
        parseFloat(extractFallbackString(d, typid))
    elif T is float32:
      case typid
      of FLOAT4OID: DatumGetFloat4(d)
      of FLOAT8OID: float32(DatumGetFloat8(d))
      of INT2OID, INT4OID, INT8OID, OIDOID: float32(extractInt64(d, typid))
      of NUMERICOID:
        let np = pgxDatumGetNumeric(d)
        if np == nil: 0.0'f32
        else:
          let r = float32(pgxNumericToFloat8(np))
          if isDetoastedPtr(d, np): safePfree(np)
          r
      else:
        float32(parseFloat(extractFallbackString(d, typid)))
    elif T is bool:
      case typid
      of BOOLOID: DatumGetBool(d)
      of INT2OID, INT4OID, INT8OID, OIDOID: extractInt64(d, typid) != 0
      else:
        let s = extractFallbackString(d, typid)
        s == "t" or s == "true" or s == "1" or s == "TRUE"
    elif T is char:
      case typid
      of CHAROID: char(DatumGetChar(d))
      of INT2OID, INT4OID, INT8OID:
        let v = extractInt64(d, typid)
        if v < 0 or v > 255:
          raise newException(ValueError, "Integer value " & $v & " out of range for char")
        char(v)
      else:
        let s = extractFallbackString(d, typid)
        if s.len > 0: s[0] else: '\0'
    elif T is string:
      extractFallbackString(d, typid)
    elif T is PgText:
      if isTextOrJsonOid(typid):
        let detoasted = pgxSpiDetoastPacked(d)
        if detoasted == nil:
          return initPgText()
        let n = int(pgxSpiVarlenaLen(detoasted))
        let data = pgxSpiVarlenaData(detoasted)
        if n <= 0 or data == nil:
          if pgxSpiIsDetoastedCopy(d, detoasted): safePfree(detoasted)
          return initPgText()
        let buf = palloc(cuint(n))
        copyMem(buf, cast[pointer](data), n)
        if pgxSpiIsDetoastedCopy(d, detoasted): safePfree(detoasted)
        PgText(raw: nil, dataPtr: cast[ptr UncheckedArray[char]](buf), len: n)
      else:
        let s = extractFallbackString(d, typid)
        if s.len == 0:
          return initPgText()
        let buf = palloc(cuint(s.len))
        copyMem(buf, unsafeAddr s[0], s.len)
        PgText(raw: nil, dataPtr: cast[ptr UncheckedArray[char]](buf), len: s.len)
    elif T is PgBytea:
      if typid == BYTEAOID:
        let detoasted = pgxSpiDetoastPacked(d)
        if detoasted == nil:
          return initPgBytea()
        let n = int(pgxSpiVarlenaLen(detoasted))
        let data = pgxSpiVarlenaData(detoasted)
        if n > 0 and data != nil:
          var buf = newSeq[byte](n)
          copyMem(addr buf[0], cast[pointer](data), n)
          result = PgBytea(raw: nil, dataPtr: nil, len: n, owned: move(buf))
        else:
          result = initPgBytea()
        if pgxSpiIsDetoastedCopy(d, detoasted):
          safePfree(detoasted)
      else:
        result = fromHexBytea(extractFallbackString(d, typid))
    elif T is PgUuid:
      if typid == UUIDOID: getPgUuid(d)
      else: parsePgUuid(extractFallbackString(d, typid))
    elif T is PgDate:
      if typid == DATEOID: getPgDate(d)
      else: parsePgDate(extractFallbackString(d, typid))
    elif T is PgTimestamp:
      if typid == TIMESTAMPOID: getPgTimestamp(d)
      elif typid == TIMESTAMPTZOID: PgTimestamp(usec: getPgTimestampTz(d).usec)
      else: parsePgTimestamp(extractFallbackString(d, typid))
    elif T is PgTimestampTz:
      if typid == TIMESTAMPTZOID: getPgTimestampTz(d)
      elif typid == TIMESTAMPOID: PgTimestampTz(usec: getPgTimestamp(d).usec)
      else: parsePgTimestampTz(extractFallbackString(d, typid))
    elif T is PgInterval:
      if typid == INTERVALOID: getPgInterval(d)
      else: parsePgInterval(extractFallbackString(d, typid))
    elif T is PgNumeric:
      if typid == NUMERICOID: pgNumeric(extractNumericOut(d))
      else: pgNumeric(extractFallbackString(d, typid))
    elif T is JsonNode:
      {.cast(tags: []).}:
        if typid == JSONBOID:
          DatumToJsonNode(d)
        elif isTextOrJsonOid(typid):
          let s = extractDirectText(d)
          if s.len == 0: newJNull() else: parseJson(s)
        else:
          let s = extractFallbackString(d, typid)
          if s.len == 0: newJNull() else: parseJson(s)
    elif T is enum:
      if isTextOid(typid):
        parseEnum[T](extractDirectText(d))
      else:
        oidToEnum[T](DatumGetObjectId(d))
    elif T is seq:
      if isTextOid(typid):
        return parseValue[T](extractDirectText(d))
      type ElemT = typeof(default(T)[0])
      let arrPtr = DatumGetArrayTypeP(d)
      if arrPtr == nil:
        return @[]
      let elemOid = arrPtr.elemtype
      var tlen: int16 = 0
      var tbyval = false
      var talign = 'i'
      getElemTypeLayout(elemOid, tlen, tbyval, talign)
      var elemsPtr: ptr Datum = nil
      var nullsPtr: ptr bool = nil
      var nElems: cint = 0
      {.cast(tags: []).}:
        deconstruct_array(arrPtr, elemOid, cint(tlen), tbyval, talign.cchar, addr elemsPtr, addr nullsPtr, addr nElems)
      let elemArr = cast[ptr UncheckedArray[Datum]](elemsPtr)
      let nullArr = cast[ptr UncheckedArray[bool]](nullsPtr)
      result = newSeq[ElemT](int(nElems))
      for i in 0 ..< int(nElems):
        let eNull = (nullArr != nil and nullArr[i])
        result[i] = datumToNim[ElemT](elemArr[i], elemOid, eNull)
      if elemsPtr != nil: safePfree(elemsPtr)
      if nullsPtr != nil: safePfree(nullsPtr)
      if isDetoastedPtr(d, arrPtr):
        safePfree(arrPtr)
    elif T is object:
      {.cast(tags: []).}:
        tupleHeaderToObject[T](DatumGetHeapTupleHeader(d))
    else:
      default(T)

# =============================================================================
# SPI Initialization & Query Templates
# =============================================================================

var SPI_processed* {.importc: "SPI_processed", header: "executor/spi.h".}: uint64
var SPI_tuptable* {.importc: "SPI_tuptable", header: "executor/spi.h".}: TupleTable

{.emit: """
#include "utils/memutils.h"
void *pgx_spi_get_current_ctx(void) {
  return (void *)CurrentMemoryContext;
}
void *pgx_spi_set_current_ctx(void *ctx) {
  if (ctx != NULL) {
    return (void *)MemoryContextSwitchTo((MemoryContext)ctx);
  }
  MemoryContext old = CurrentMemoryContext;
  CurrentMemoryContext = (MemoryContext)0;
  return (void *)old;
}
""".}

proc pgxSpiGetCurrentCtx*(): pointer {.importc: "pgx_spi_get_current_ctx".}
proc pgxSpiSetCurrentCtx*(ctx: pointer): pointer {.importc: "pgx_spi_set_current_ctx".}

proc pgxSpiCopyStr(s: string): string =
  if s.len == 0:
    return ""
  result = newString(s.len)
  copyMem(addr result[0], unsafeAddr s[0], s.len)

proc pgxCloneExceptionBase[T: Exception](src: ref Exception): ref T =
  var cloned: ref T
  new(cloned)
  cloned.name = src.name
  cloned.msg = pgxSpiCopyStr(src.msg)
  result = cloned

proc pgxClonePgFields[T](dst, src: ref T) =
  dst.sqlerrcode = src.sqlerrcode
  dst.detail = pgxSpiCopyStr(src.detail)
  dst.hint = pgxSpiCopyStr(src.hint)
  dst.context = pgxSpiCopyStr(src.context)

proc pgxReallocCaughtError*(e: ref CatchableError, outerCtx: pointer): ref CatchableError =
  let savedCtx = pgxSpiSetCurrentCtx(outerCtx)
  try:
    if e of PostgresError:
      let pg = pgxCloneExceptionBase[PostgresError](e)
      pgxClonePgFields(pg, (ref PostgresError)(e))
      result = pg
    elif e of PgError:
      let pg = pgxCloneExceptionBase[PgError](e)
      pgxClonePgFields(pg, (ref PgError)(e))
      result = pg
    elif e of ValueError:
      result = pgxCloneExceptionBase[ValueError](e)
    else:
      result = pgxCloneExceptionBase[CatchableError](e)
  finally:
    discard pgxSpiSetCurrentCtx(savedCtx)

proc pgxReallocCaughtDefect*(d: ref Defect, outerCtx: pointer): ref Defect =
  let savedCtx = pgxSpiSetCurrentCtx(outerCtx)
  try:
    result = pgxCloneExceptionBase[Defect](d)
  finally:
    discard pgxSpiSetCurrentCtx(savedCtx)

template spi_init*(statements: untyped) =
  var spiOuterCtx = pgxSpiGetCurrentCtx()
  var connection_status {.used.} = connect()
  if connection_status < 0:
    let errName = result_code_string(connection_status)
    var ex = newException(PostgresError, "SPI_connect failed: " & $errName)
    ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
    raise ex
  if spiOuterCtx != nil:
    discard pgxSpiSetCurrentCtx(spiOuterCtx)
  var spiPendingErr: ref CatchableError = nil
  var spiPendingDefect: ref Defect = nil
  try:
    statements
  except CatchableError as e:
    spiPendingErr = pgxReallocCaughtError(e, spiOuterCtx)
  except Defect as d:
    spiPendingDefect = pgxReallocCaughtDefect(d, spiOuterCtx)
  var finish_status {.used.} = finish()
  if spiPendingDefect != nil:
    raise spiPendingDefect
  if spiPendingErr != nil:
    raise spiPendingErr

template spiNonAtomic*(statements: untyped) =
  ## Connects to SPI in non-atomic mode (SPI_OPT_NONATOMIC) for PROCEDURE transaction control
  ## (`spiCommit`, `spiCommitAndChain`, `spiRollback`, `spiRollbackAndChain`).
  var spiOuterCtx = pgxSpiGetCurrentCtx()
  var connection_status {.used.} = connectExt(pgxSpiNonAtomicOpt())
  if connection_status < 0:
    let errName = result_code_string(connection_status)
    var ex = newException(PostgresError, "SPI_connect_ext(SPI_OPT_NONATOMIC) failed: " & $errName)
    ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
    raise ex
  if spiOuterCtx != nil:
    discard pgxSpiSetCurrentCtx(spiOuterCtx)
  var spiPendingErr: ref CatchableError = nil
  var spiPendingDefect: ref Defect = nil
  try:
    statements
  except CatchableError as e:
    spiPendingErr = pgxReallocCaughtError(e, spiOuterCtx)
  except Defect as d:
    spiPendingDefect = pgxReallocCaughtDefect(d, spiOuterCtx)
  var finish_status {.used.} = finish()
  if spiPendingDefect != nil:
    raise spiPendingDefect
  if spiPendingErr != nil:
    raise spiPendingErr

proc spiCommit*() {.tags: [DbWriteEffect].} =
  ## Commits the current transaction inside a non-atomic PROCEDURE `spiNonAtomic` block.
  pgxMarkDbWrite()
  pgTry:
    spiCommitRaw()

proc spiCommitAndChain*() {.tags: [DbWriteEffect].} =
  ## Commits the current transaction and starts a new chained transaction with identical characteristics.
  pgxMarkDbWrite()
  pgTry:
    spiCommitAndChainRaw()

proc spiRollback*() {.tags: [DbWriteEffect].} =
  ## Rolls back the current transaction inside a non-atomic PROCEDURE `spiNonAtomic` block.
  pgxMarkDbWrite()
  pgTry:
    spiRollbackRaw()

proc spiRollbackAndChain*() {.tags: [DbWriteEffect].} =
  ## Rolls back the current transaction and starts a new chained transaction with identical characteristics.
  pgxMarkDbWrite()
  pgTry:
    spiRollbackAndChainRaw()

template withSpiConnection(didConnSym, outerCtxSym, body: untyped) =
  let outerCtxSym = pgxSpiGetCurrentCtx()
  let connRc = connect()
  var didConnSym = false
  if connRc == ord(SpiError.CONNECT):
    didConnSym = false
  elif connRc < 0:
    let errName = result_code_string(connRc)
    var ex = newException(PostgresError, "SPI_connect failed: " & $errName)
    ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
    raise ex
  else:
    didConnSym = true
    if outerCtxSym != nil:
      discard pgxSpiSetCurrentCtx(outerCtxSym)
  if didConnSym:
    var spiPendingErr: ref CatchableError = nil
    var spiPendingDefect: ref Defect = nil
    try:
      body
    except CatchableError as e:
      spiPendingErr = pgxReallocCaughtError(e, outerCtxSym)
    except Defect as d:
      spiPendingDefect = pgxReallocCaughtDefect(d, outerCtxSym)
    discard finish()
    if spiPendingDefect != nil:
      raise spiPendingDefect
    if spiPendingErr != nil:
      raise spiPendingErr
  else:
    try:
      body
    finally:
      if outerCtxSym != nil:
        discard pgxSpiSetCurrentCtx(outerCtxSym)

template query*(c: const_string, obj: untyped) =
  let callerContext {.used.} = CurrentMemoryContext
  var obj {.inject.}: ResultSet = @[]
  pgTry:
    discard exec(const_string(c), 0)
    if SPI_tuptable != nil:
      let tupdesc = getTupdesc(SPI_tuptable)
      if tupdesc != nil:
        let natts = int(getNatts(tupdesc))
        if SPI_processed > 0 and natts > 0:
          let spiContext = if callerContext != nil: MemoryContextSwitchTo(callerContext) else: nil
          for rowIdx in 0 ..< int(SPI_processed):
            let tup = getTuple(SPI_tuptable, uint64(rowIdx))
            if tup != nil:
              var row: Row = @[]
              for colIdx in 1 .. natts:
                let colname = fname(tupdesc, cint(colIdx))
                let val = getvalue(tup, tupdesc, cint(colIdx))
                let k = if colname != nil: $colname else: "col_" & $colIdx
                let v = if val != nil: $val else: ""
                safePfree(cast[pointer](colname))
                safePfree(cast[pointer](val))
                row.add([(k, v)].toTable)
              if row.len > 0:
                obj.add(row)
          if spiContext != nil:
            discard MemoryContextSwitchTo(spiContext)

# =============================================================================
# Metadata Caching, Binary Parameter Binding & Execution Helpers
# =============================================================================

proc validateNoNullBytes*(sql: string) =
  ## Intercepts and rejects any SQL statement or parameter containing prohibited null bytes
  if '\0' in sql:
    raise newException(ValueError, "SQL query contains prohibited null byte character (SQL injection defense)")

proc extractColMeta*(tupdesc: TupleDesc): seq[SpiColMeta] =
  ## Extracts and caches TupleDesc column metadata once outside row loops (skipping dropped columns).
  if tupdesc == nil:
    return @[]
  let natts = int(getNatts(tupdesc))
  if natts <= 0:
    return @[]
  result = newSeqOfCap[SpiColMeta](natts)
  for colIdx in 1 .. natts:
    let attnum = cint(colIdx)
    if pgxSpiAttisdropped(tupdesc, attnum):
      continue
    let rawName = pgxSpiAttname(tupdesc, attnum)
    let colName = if rawName != nil and rawName[0] != '\0': $rawName else: "col_" & $colIdx
    let typid = pgxSpiAtttypid(tupdesc, attnum)
    result.add(SpiColMeta(attnum: attnum, name: colName, typid: typid))

proc buildFieldMap[T: object](cols: seq[SpiColMeta]): seq[SpiFieldBinding] =
  var colByName = initTable[string, int](max(4, cols.len * 2))
  for i, c in cols:
    colByName[c.name] = i
  var dummy: T
  for name, _ in fieldPairs(dummy):
    if colByName.hasKey(name):
      let c = cols[colByName[name]]
      result.add(SpiFieldBinding(attnum: c.attnum, typid: c.typid))
    else:
      result.add(SpiFieldBinding(attnum: 0, typid: 0.Oid))

proc decodeTupleTable[T: object](tuptable: TupleTable, callerCtx: pointer): seq[T] =
  mixin pgxFromDatum
  if tuptable == nil or SPI_processed == 0'u64:
    return @[]
  let tupdesc = getTupdesc(tuptable)
  if tupdesc == nil:
    return @[]
  let numRows = int(min(SPI_processed, uint64(high(int))))
  let savedCtx = if callerCtx != nil: MemoryContextSwitchTo(callerCtx) else: nil
  try:
    let cols = extractColMeta(tupdesc)
    if cols.len == 0:
      return @[]
    let fieldMap = buildFieldMap[T](cols)
    result = newSeqOfCap[T](numRows)
    for rowIdx in 0 ..< numRows:
      let tup = getTuple(tuptable, uint64(rowIdx))
      if tup == nil:
        continue
      var item: T
      var fi = 0
      for _, val in fieldPairs(item):
        let binding = fieldMap[fi]
        if binding.attnum > 0:
          var isnull = false
          let d = pgxSpiGetbinval(tup, tupdesc, binding.attnum, addr isnull)
          val = datumToNim[typeof(val)](d, binding.typid, isnull)
        inc fi
      result.add(item)
  finally:
    if savedCtx != nil:
      discard MemoryContextSwitchTo(savedCtx)

proc populateBoundParams(params: openArray[BoundParam],
                         argTypes: var seq[Oid],
                         values: var seq[Datum],
                         nulls: var seq[char]) =
  for i, p in params:
    case p.kind
    of bpNull:
      argTypes[i] = if p.nullOidHint != 0'u32: Oid(p.nullOidHint) else: UNKNOWNOID
      values[i] = Datum(0)
      nulls[i] = 'n'
    of bpBool:
      argTypes[i] = BOOLOID
      values[i] = BoolGetDatum(p.boolVal)
      nulls[i] = ' '
    of bpInt2:
      argTypes[i] = INT2OID
      values[i] = Int16GetDatum(p.int2Val)
      nulls[i] = ' '
    of bpInt4:
      argTypes[i] = INT4OID
      values[i] = Int32GetDatum(p.int4Val)
      nulls[i] = ' '
    of bpInt8:
      argTypes[i] = INT8OID
      values[i] = Int64GetDatum(p.int8Val)
      nulls[i] = ' '
    of bpFloat4:
      argTypes[i] = FLOAT4OID
      values[i] = Float4GetDatum(p.float4Val)
      nulls[i] = ' '
    of bpFloat8:
      argTypes[i] = FLOAT8OID
      values[i] = Float8GetDatum(p.float8Val)
      nulls[i] = ' '
    of bpText:
      validateNoNullBytes(p.textVal)
      argTypes[i] = TEXTOID
      values[i] = returnPgText(p.textVal)
      nulls[i] = ' '
    of bpJsonb:
      argTypes[i] = JSONBOID
      if p.jsonbVal.isNil:
        values[i] = Datum(0)
        nulls[i] = 'n'
      else:
        values[i] = JsonNodeToDatum(p.jsonbVal)
        nulls[i] = ' '
    of bpBytea:
      argTypes[i] = BYTEAOID
      values[i] = returnPgBytea(p.byteaVal)
      nulls[i] = ' '
    of bpUuid:
      argTypes[i] = UUIDOID
      values[i] = returnPgUuid(PgUuid(bytes: p.uuidBytes))
      nulls[i] = ' '
    of bpDate:
      argTypes[i] = DATEOID
      values[i] = returnPgDate(PgDate(days: p.dateDays))
      nulls[i] = ' '
    of bpTimestamp:
      argTypes[i] = TIMESTAMPOID
      values[i] = returnPgTimestamp(PgTimestamp(usec: p.tsUsec))
      nulls[i] = ' '
    of bpTimestampTz:
      argTypes[i] = TIMESTAMPTZOID
      values[i] = returnPgTimestampTz(PgTimestampTz(usec: p.tstzUsec))
      nulls[i] = ' '
    of bpInterval:
      argTypes[i] = INTERVALOID
      values[i] = returnPgInterval(PgInterval(usec: p.ivUsec, days: p.ivDays, months: p.ivMonths))
      nulls[i] = ' '
    of bpNumeric:
      validateNoNullBytes(p.numericLit)
      argTypes[i] = NUMERICOID
      values[i] = returnPgNumeric(pgNumeric(p.numericLit))
      nulls[i] = ' '
    of bpTextArray:
      for s in p.textArr:
        validateNoNullBytes(s)
      argTypes[i] = TEXTARRAYOID
      values[i] = returnArrayString(p.textArr)
      nulls[i] = ' '
    of bpInt4Array:
      argTypes[i] = INT4ARRAYOID
      values[i] = returnArrayInt32(p.int4Arr)
      nulls[i] = ' '
    of bpInt8Array:
      argTypes[i] = INT8ARRAYOID
      values[i] = returnArrayInt64(p.int8Arr)
      nulls[i] = ' '
    of bpFloat8Array:
      argTypes[i] = FLOAT8ARRAYOID
      values[i] = returnArrayFloat64(p.float8Arr)
      nulls[i] = ' '
    of bpBoolArray:
      argTypes[i] = BOOLARRAYOID
      values[i] = returnArrayBool(p.boolArr)
      nulls[i] = ' '

proc raiseIfSpiError(rc: cint, op: string) =
  if rc < 0:
    var ex = newException(PostgresError, op & " failed: " & $result_code_string(rc))
    ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
    raise ex

proc execSpiQuery(sql: string, params: openArray[BoundParam], readOnly: bool, count: clong, callerCtx: pointer): cint =
  validateNoNullBytes(sql)
  let effReadOnly = pgxSpiEffectiveReadOnly(readOnly)
  var rc: cint = 0
  if params.len == 0:
    pgTry:
      rc = pgxSpiExecute(const_string(sql), effReadOnly, count)
    raiseIfSpiError(rc, "SPI_execute")
    return rc

  let paramsSeq = @params
  let n = paramsSeq.len
  var argTypes = newSeq[Oid](n)
  var values = newSeq[Datum](n)
  var nulls = newSeq[char](n + 1)
  nulls[n] = '\0'
  let subCtx = createMemoryContext(callerCtx, "pgx_spi_args")
  try:
    pgTry:
      withMemoryContext(subCtx):
        populateBoundParams(paramsSeq, argTypes, values, nulls)
      rc = pgxSpiExecuteWithArgs(
        const_string(sql), cint(n),
        addr argTypes[0], addr values[0], cast[const_string](addr nulls[0]),
        effReadOnly, count
      )
  finally:
    deleteMemoryContext(subCtx)
  raiseIfSpiError(rc, "SPI_execute_with_args")
  return rc

proc isReadOnlyQuery*(q: ExecutableQuery): bool {.inline.} =
  q.state.kind in {skSelect, skValues}

# =============================================================================
# High-Level SPI Consumer Procs (Eager Fetch, Optionals, Reducers)
# =============================================================================

proc fetchRawRows*(sqlQuery: string, params: openArray[BoundParam], readOnly: bool = false): seq[Table[string, string]] {.tags: [
    DbReadEffect].} =
  ## Executes raw or parameterized SQL via SPI and returns a flat seq of row tables (caching column names outside row loop).
  validateNoNullBytes(sqlQuery)
  var rows = new(seq[Table[string, string]])
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(sqlQuery, params, readOnly, 0, callerContext)
    if SPI_tuptable != nil:
      try:
        let tupdesc = getTupdesc(SPI_tuptable)
        if tupdesc != nil and SPI_processed > 0:
          let numRows = int(min(SPI_processed, uint64(high(int))))
          let savedCtx = if callerContext != nil: MemoryContextSwitchTo(callerContext) else: nil
          try:
            let cols = extractColMeta(tupdesc)
            if cols.len > 0:
              rows[] = newSeqOfCap[Table[string, string]](numRows)
              for rowIdx in 0 ..< numRows:
                let tup = getTuple(SPI_tuptable, uint64(rowIdx))
                if tup != nil:
                  var rowTable = initTable[string, string](max(4, cols.len * 2))
                  for col in cols:
                    let val = getvalue(tup, tupdesc, col.attnum)
                    let v = if val != nil: $val else: ""
                    safePfree(cast[pointer](val))
                    rowTable[col.name] = v
                  rows[].add(rowTable)
          finally:
            if savedCtx != nil:
              discard MemoryContextSwitchTo(savedCtx)
      finally:
        if not didConn:
          pgxSpiFreetuptableIfSet()
  return rows[]

proc fetchRawRows*(sqlQuery: string): seq[Table[string, string]] {.tags: [
    DbReadEffect].} =
  ## Internal: Executes raw SQL via SPI and returns a flat seq of row tables
  fetchRawRows(sqlQuery, @[], readOnly = false)

proc fetchRows*(query: ExecutableQuery): seq[Table[string, string]] {.tags: [
    DbReadEffect].} =
  ## Executes a fluent query via binary parameterized SPI and returns rows as key-value string tables
  let pq = toParameterizedSql(query)
  fetchRawRows(pq.sql, pq.params, readOnly = query.isReadOnlyQuery())

proc fetch*[T: object](query: ExecutableQuery): seq[T] {.tags: [
    DbReadEffect].} =
  ## Maps fluent query result rows directly into a sequence of typed Nim objects via binary SPI
  mixin pgxFromDatum
  let pq = toParameterizedSql(query)
  validateNoNullBytes(pq.sql)
  let readOnly = query.isReadOnlyQuery()
  var items = new(seq[T])
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(pq.sql, pq.params, readOnly, 0, callerContext)
    if SPI_tuptable != nil:
      try:
        items[] = decodeTupleTable[T](SPI_tuptable, callerContext)
      finally:
        if not didConn:
          pgxSpiFreetuptableIfSet()
  return items[]

proc fetch*[T: object](query: ExecutableQuery, _: typedesc[T]): seq[T] {.tags: [
    DbReadEffect].} =
  mixin pgxFromDatum
  fetch[T](query)

proc fetchOne*[T: object](query: ExecutableQuery): Option[T] {.tags: [
    DbReadEffect].} =
  ## Fetches the first row of a fluent query as an Option[T], or none(T) if empty
  mixin pgxFromDatum
  let pq = toParameterizedSql(query)
  validateNoNullBytes(pq.sql)
  let readOnly = query.isReadOnlyQuery()
  let spiCount: clong = if readOnly: 1 else: 0
  var resOpt = new(Option[T])
  resOpt[] = none(T)
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(pq.sql, pq.params, readOnly, spiCount, callerContext)
    if SPI_tuptable != nil and SPI_processed > 0'u64:
      try:
        let tupdesc = getTupdesc(SPI_tuptable)
        if tupdesc != nil:
          let tup = getTuple(SPI_tuptable, 0'u64)
          if tup != nil:
            let savedCtx = if callerContext != nil: MemoryContextSwitchTo(callerContext) else: nil
            try:
              let cols = extractColMeta(tupdesc)
              if cols.len > 0:
                let fieldMap = buildFieldMap[T](cols)
                var item: T
                var fi = 0
                for _, val in fieldPairs(item):
                  let binding = fieldMap[fi]
                  if binding.attnum > 0:
                    var isnull = false
                    let d = pgxSpiGetbinval(tup, tupdesc, binding.attnum, addr isnull)
                    val = datumToNim[typeof(val)](d, binding.typid, isnull)
                  inc fi
                resOpt[] = some(item)
            finally:
              if savedCtx != nil:
                discard MemoryContextSwitchTo(savedCtx)
      finally:
        if not didConn:
          pgxSpiFreetuptableIfSet()
  return resOpt[]

proc fetchOne*[T: object](query: ExecutableQuery, _: typedesc[T]): Option[
    T] {.tags: [DbReadEffect].} =
  mixin pgxFromDatum
  fetchOne[T](query)

proc fetchScalar*[T](query: ExecutableQuery): T {.tags: [DbReadEffect].} =
  ## Fetches a single scalar value from the first column of the first row (e.g. COUNT(*), SUM(x))
  mixin pgxFromDatum
  let pq = toParameterizedSql(query)
  validateNoNullBytes(pq.sql)
  let readOnly = query.isReadOnlyQuery()
  let spiCount: clong = if readOnly: 1 else: 0
  var outBox = new(T)
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(pq.sql, pq.params, readOnly, spiCount, callerContext)
    try:
      let savedCtx = if callerContext != nil: MemoryContextSwitchTo(callerContext) else: nil
      try:
        if SPI_tuptable != nil and SPI_processed > 0'u64:
          let tupdesc = getTupdesc(SPI_tuptable)
          let cols = extractColMeta(tupdesc)
          let tup = getTuple(SPI_tuptable, 0'u64)
          if tupdesc != nil and cols.len > 0 and tup != nil:
            var isnull = false
            let d = pgxSpiGetbinval(tup, tupdesc, cols[0].attnum, addr isnull)
            outBox[] = datumToNim[T](d, cols[0].typid, isnull)
          else:
            outBox[] = datumToNim[T](Datum(0), 0.Oid, true)
        else:
          outBox[] = datumToNim[T](Datum(0), 0.Oid, true)
      finally:
        if savedCtx != nil:
          discard MemoryContextSwitchTo(savedCtx)
    finally:
      if not didConn and SPI_tuptable != nil:
        pgxSpiFreetuptableIfSet()
  return outBox[]

proc fetchCount*(query: ExecutableQuery): int {.tags: [DbReadEffect].} =
  ## Executes fluent query and returns total processed count
  let pq = toParameterizedSql(query)
  validateNoNullBytes(pq.sql)
  let readOnly = query.isReadOnlyQuery()
  var cnt = 0
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(pq.sql, pq.params, readOnly, 0, callerContext)
    cnt = int(min(SPI_processed, uint64(high(int))))
    if not didConn and SPI_tuptable != nil:
      pgxSpiFreetuptableIfSet()
  return cnt

# =============================================================================
# Fluent Terminal Chain Methods (.scalar, .first, .all, .rows, .run, .execute)
# =============================================================================

proc scalar*[T](query: ExecutableQuery, _: typedesc[T]): T {.tags: [
    DbReadEffect].} =
  ## Fetches a single scalar value by passing type as argument: query.scalar(float64)
  mixin pgxFromDatum
  fetchScalar[T](query)

proc scalar*[T](query: ExecutableQuery): T {.tags: [DbReadEffect].} =
  ## Fetches a single scalar value using generic parameter: query.scalar[float64]()
  mixin pgxFromDatum
  fetchScalar[T](query)

proc first*[T: object](query: ExecutableQuery, _: typedesc[T]): Option[
    T] {.tags: [DbReadEffect].} =
  ## Fetches the first row as an Option[T] by passing type as argument: query.first(User)
  mixin pgxFromDatum
  fetchOne[T](query)

proc first*[T: object](query: ExecutableQuery): Option[T] {.tags: [
    DbReadEffect].} =
  ## Fetches the first row as an Option[T] using generic parameter: query.first[User]()
  mixin pgxFromDatum
  fetchOne[T](query)

proc all*[T: object](query: ExecutableQuery, _: typedesc[T]): seq[T] {.tags: [
    DbReadEffect].} =
  ## Fetches all rows mapped to object T by passing type as argument: query.all(User)
  mixin pgxFromDatum
  fetch[T](query)

proc all*[T: object](query: ExecutableQuery): seq[T] {.tags: [
    DbReadEffect].} =
  ## Fetches all rows mapped to object T using generic parameter: query.all[User]()
  mixin pgxFromDatum
  fetch[T](query)

proc rows*(query: ExecutableQuery): seq[Table[string, string]] {.tags: [
    DbReadEffect].} =
  ## Fetches dynamic key-value rows: query.rows()
  fetchRows(query)

proc run*(query: ExecutableQuery): int {.discardable, tags: [DbWriteEffect].} =
  ## Executes a DML statement (INSERT, UPDATE, DELETE) via parameterized binary SPI.
  ## Returns affected rows. Marked {.discardable.} so 'discard' is never required.
  pgxMarkDbWrite()
  let pq = toParameterizedSql(query)
  validateNoNullBytes(pq.sql)
  var ret = 0
  withSpiConnection(didConn, callerContext):
    discard execSpiQuery(pq.sql, pq.params, query.isReadOnlyQuery(), 0, callerContext)
    ret = int(min(SPI_processed, uint64(high(int))))
    if not didConn and SPI_tuptable != nil:
      pgxSpiFreetuptableIfSet()
  return ret

# =============================================================================
# Prepared Plans (SpiPlan)
# =============================================================================

proc spiPrepare*(sql: string, argTypes: openArray[Oid], keep: bool = false): SpiPlan {.tags: [DbReadEffect].} =
  ## Prepares a parameterized SPI execution plan for repeated binary execution.
  validateNoNullBytes(sql)
  let oids = @argTypes
  var planOut: SPIPlanPtr = nil
  var keptOut = false
  withSpiConnection(didConn, callerContext):
    pgTry:
      planOut = spiPrepareRaw(
        const_string(sql),
        cint(oids.len),
        if oids.len > 0: unsafeAddr oids[0] else: nil
      )
      if planOut == nil:
        raiseIfSpiError(pgxSpiGetResult(), "SPI_prepare")
      if keep or didConn:
        let krc = spiKeepplanRaw(planOut)
        if krc < 0:
          discard spiFreeplanRaw(planOut)
          planOut = nil
          raiseIfSpiError(krc, "SPI_keepplan")
        keptOut = true
  SpiPlan(raw: planOut, nargs: oids.len, kept: keptOut)

proc execPreparedPlan(plan: SpiPlan, args: openArray[BoundParam], readOnly: bool, count: clong, callerCtx: pointer): cint =
  if plan.raw == nil:
    raise newException(ValueError, "Cannot execute a freed or nil SpiPlan")
  if args.len != plan.nargs:
    raise newException(ValueError, "Argument count mismatch for SpiPlan: expected " & $plan.nargs & ", got " & $args.len)
  let effReadOnly = pgxSpiEffectiveReadOnly(readOnly)
  var rc: cint = 0
  if args.len == 0:
    pgTry:
      rc = pgxSpiExecutePlan(plan.raw, nil, nil, effReadOnly, count)
    raiseIfSpiError(rc, "SPI_execute_plan")
    return rc

  let argsSeq = @args
  let n = argsSeq.len
  var argTypes = newSeq[Oid](n)
  var values = newSeq[Datum](n)
  var nulls = newSeq[char](n + 1)
  nulls[n] = '\0'
  let subCtx = createMemoryContext(callerCtx, "pgx_spi_plan_args")
  try:
    pgTry:
      withMemoryContext(subCtx):
        populateBoundParams(argsSeq, argTypes, values, nulls)
      rc = pgxSpiExecutePlan(
        plan.raw,
        addr values[0],
        cast[const_string](addr nulls[0]),
        effReadOnly,
        count
      )
  finally:
    deleteMemoryContext(subCtx)
  raiseIfSpiError(rc, "SPI_execute_plan")
  return rc

proc executePlan*(plan: SpiPlan, args: openArray[BoundParam] = @[],
                  readOnly: bool = false, count: clong = 0): int {.discardable, tags: [DbWriteEffect].} =
  ## Executes a prepared SpiPlan with binary arguments and returns affected row count.
  pgxMarkDbWrite()
  if plan.raw == nil:
    raise newException(ValueError, "Cannot execute a freed or nil SpiPlan")
  if args.len != plan.nargs:
    raise newException(ValueError, "Argument count mismatch for SpiPlan: expected " & $plan.nargs & ", got " & $args.len)
  var ret = 0
  withSpiConnection(didConn, callerContext):
    discard execPreparedPlan(plan, args, readOnly, count, callerContext)
    ret = int(min(SPI_processed, uint64(high(int))))
    if not didConn and SPI_tuptable != nil:
      pgxSpiFreetuptableIfSet()
  return ret

proc fetchPlan*[T: object](plan: SpiPlan, args: openArray[BoundParam] = @[],
                           readOnly: bool = true, count: clong = 0): seq[T] {.tags: [DbReadEffect].} =
  ## Executes a prepared SpiPlan and decodes returned rows directly into seq[T].
  mixin pgxFromDatum
  if plan.raw == nil:
    raise newException(ValueError, "Cannot fetch from a freed or nil SpiPlan")
  if args.len != plan.nargs:
    raise newException(ValueError, "Argument count mismatch for SpiPlan: expected " & $plan.nargs & ", got " & $args.len)
  var items = new(seq[T])
  withSpiConnection(didConn, callerContext):
    discard execPreparedPlan(plan, args, readOnly, count, callerContext)
    if SPI_tuptable != nil:
      try:
        items[] = decodeTupleTable[T](SPI_tuptable, callerContext)
      finally:
        if not didConn:
          pgxSpiFreetuptableIfSet()
  return items[]

proc free*(plan: var SpiPlan) {.tags: [].} =
  ## Frees a prepared SpiPlan cleanly (idempotent and double-free safe).
  if plan.raw != nil:
    discard spiFreeplanRaw(plan.raw)
    plan.raw = nil
  plan.nargs = 0
  plan.kept = false

# =============================================================================
# Streaming Cursors & Iterators (SpiCursor, stream, fetchBatches)
# =============================================================================

proc spiCursorOpen*(name: string, sql: string, args: openArray[BoundParam] = @[],
                    readOnly: bool = true, cursorOptions: cint = 0): SpiCursor {.tags: [DbReadEffect].} =
  ## Opens a server-side SPI portal cursor for bounded-memory batch streaming.
  validateNoNullBytes(sql)
  validateNoNullBytes(name)
  let argsSeq = @args
  let outerCtx = pgxSpiGetCurrentCtx()
  let connRc = connect()
  var ownsConn = false
  if connRc == ord(SpiError.CONNECT):
    ownsConn = false
  elif connRc < 0:
    let errName = result_code_string(connRc)
    var ex = newException(PostgresError, "SPI_connect failed: " & $errName)
    ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
    raise ex
  else:
    ownsConn = true
    if outerCtx != nil:
      discard pgxSpiSetCurrentCtx(outerCtx)

  var portal: Portal = nil
  var openErr: ref CatchableError = nil
  var openDefect: ref Defect = nil
  try:
    let cName: const_string = if name.len > 0: const_string(name) else: const_string(nil)
    let effReadOnly = pgxSpiEffectiveReadOnly(readOnly)
    if args.len == 0:
      pgTry:
        portal = pgxSpiCursorOpenWithArgs(cName, const_string(sql), 0'i32, nil, nil, nil, effReadOnly, cursorOptions)
    else:
      let n = argsSeq.len
      var argTypes = newSeq[Oid](n)
      var values = newSeq[Datum](n)
      var nulls = newSeq[char](n + 1)
      nulls[n] = '\0'
      let subCtx = createMemoryContext(outerCtx, "pgx_spi_cursor_args")
      try:
        pgTry:
          withMemoryContext(subCtx):
            populateBoundParams(argsSeq, argTypes, values, nulls)
          portal = pgxSpiCursorOpenWithArgs(
            cName, const_string(sql), cint(n),
            addr argTypes[0], addr values[0], cast[const_string](addr nulls[0]),
            effReadOnly, cursorOptions
          )
      finally:
        deleteMemoryContext(subCtx)
    if portal == nil:
      let rc = pgxSpiGetResult()
      var ex = newException(PostgresError, "SPI_cursor_open_with_args failed: " & $result_code_string(rc))
      ex.sqlerrcode = ERRCODE_INTERNAL_ERROR
      raise ex
  except CatchableError as e:
    openErr = if ownsConn: pgxReallocCaughtError(e, outerCtx) else: e
  except Defect as d:
    openDefect = if ownsConn: pgxReallocCaughtDefect(d, outerCtx) else: d
  finally:
    if outerCtx != nil:
      discard pgxSpiSetCurrentCtx(outerCtx)

  if openDefect != nil:
    if ownsConn: discard finish()
    raise openDefect
  if openErr != nil:
    if ownsConn: discard finish()
    raise openErr

  SpiCursor(portal: portal, name: name, closed: false, ownsSpiConn: ownsConn, outerCtx: outerCtx)

proc spiCursorOpen*(name: string, q: ExecutableQuery, cursorOptions: cint = 0): SpiCursor {.tags: [DbReadEffect].} =
  ## Overload opening a server-side SPI cursor directly from an ExecutableQuery.
  let pq = toParameterizedSql(q)
  spiCursorOpen(name, pq.sql, pq.params, readOnly = q.isReadOnlyQuery(), cursorOptions = cursorOptions)

proc spiCursorFetch*[T: object](cur: SpiCursor, batchSize: int = 1000): seq[T] {.tags: [DbReadEffect].} =
  ## Fetches up to `batchSize` rows from an open SpiCursor and decodes them into seq[T].
  mixin pgxFromDatum
  if cur.closed or cur.portal == nil:
    raise newException(ValueError, "Cannot fetch from a closed SpiCursor")
  if batchSize <= 0:
    raise newException(ValueError, "batchSize must be > 0, got " & $batchSize)
  let entryCtx = pgxSpiGetCurrentCtx()
  let callerCtx = if cur.outerCtx != nil: cur.outerCtx else: entryCtx
  var rowsOut: seq[T] = @[]
  var fetchErr: ref CatchableError = nil
  var fetchDefect: ref Defect = nil
  try:
    pgTry:
      spiCursorFetchRaw(cur.portal, true, clong(batchSize))
      if SPI_tuptable != nil:
        try:
          rowsOut = decodeTupleTable[T](SPI_tuptable, callerCtx)
        finally:
          pgxSpiFreetuptableIfSet()
  except CatchableError as e:
    fetchErr = if cur.ownsSpiConn: pgxReallocCaughtError(e, callerCtx) else: e
  except Defect as d:
    fetchDefect = if cur.ownsSpiConn: pgxReallocCaughtDefect(d, callerCtx) else: d
  finally:
    if entryCtx != nil:
      discard pgxSpiSetCurrentCtx(entryCtx)
  if fetchDefect != nil:
    raise fetchDefect
  if fetchErr != nil:
    raise fetchErr
  return rowsOut

proc spiCursorClose*(cur: var SpiCursor) {.tags: [DbReadEffect].} =
  ## Closes an open SpiCursor portal (idempotent; also closes SPI connection if owned by cursor).
  if cur.closed:
    return
  cur.closed = true
  let entryCtx = pgxSpiGetCurrentCtx()
  var closeErr: ref CatchableError = nil
  var closeDefect: ref Defect = nil
  if cur.portal != nil:
    let p = cur.portal
    cur.portal = nil
    try:
      pgTry:
        spiCursorCloseRaw(p)
    except CatchableError as e:
      closeErr = if cur.ownsSpiConn: pgxReallocCaughtError(e, cur.outerCtx) else: e
    except Defect as d:
      closeDefect = if cur.ownsSpiConn: pgxReallocCaughtDefect(d, cur.outerCtx) else: d
  if cur.ownsSpiConn:
    cur.ownsSpiConn = false
    discard finish()
  elif entryCtx != nil:
    discard pgxSpiSetCurrentCtx(entryCtx)
  elif cur.outerCtx != nil:
    discard pgxSpiSetCurrentCtx(cur.outerCtx)
  if closeDefect != nil:
    raise closeDefect
  if closeErr != nil:
    raise closeErr

iterator fetchBatches*[T: object](q: ExecutableQuery, batchSize: int = 1000): seq[T] {.tags: [DbReadEffect].} =
  ## Streams query results in bounded-memory batches via server-side SPI cursor; always closes portal on early break/error.
  mixin pgxFromDatum
  if batchSize <= 0:
    raise newException(ValueError, "batchSize must be > 0, got " & $batchSize)
  let pq = toParameterizedSql(q)
  validateNoNullBytes(pq.sql)
  var cur = spiCursorOpen("", pq.sql, pq.params, readOnly = q.isReadOnlyQuery())
  try:
    while true:
      let batch = spiCursorFetch[T](cur, batchSize)
      if batch.len == 0:
        break
      yield batch
  finally:
    spiCursorClose(cur)

iterator stream*[T: object](q: ExecutableQuery, batchSize: int = 1000): T {.tags: [DbReadEffect].} =
  ## Streams query results row-by-row over a bounded-memory SPI cursor; always closes portal on early break/error.
  mixin pgxFromDatum
  if batchSize <= 0:
    raise newException(ValueError, "batchSize must be > 0, got " & $batchSize)
  let pq = toParameterizedSql(q)
  validateNoNullBytes(pq.sql)
  var cur = spiCursorOpen("", pq.sql, pq.params, readOnly = q.isReadOnlyQuery())
  try:
    while true:
      let batch = spiCursorFetch[T](cur, batchSize)
      if batch.len == 0:
        break
      for item in batch:
        yield item
  finally:
    spiCursorClose(cur)

# =============================================================================
# Subtransactions & Savepoints (Internal Nested Transactions)
# =============================================================================

proc BeginInternalSubTransaction*(name: cstring = nil) {.importc,
    header: "access/xact.h".}
proc ReleaseCurrentSubTransaction*() {.importc, header: "access/xact.h".}
proc RollbackAndReleaseCurrentSubTransaction*() {.importc,
    header: "access/xact.h".}
proc IsSubTransaction*(): bool {.importc, header: "access/xact.h".}

var CurrentResourceOwner* {.importc: "CurrentResourceOwner",
    header: "utils/resowner.h".}: pointer
proc subxMemoryContextSwitchTo*(context: pointer): pointer {.inline, discardable.} =
  MemoryContextSwitchTo(context)

template subTransaction*(body: untyped) =
  ## Executes body inside an internal nested subtransaction (savepoint).
  ## If an exception or defect occurs, changes within body are rolled back
  ## without invalidating the parent transaction, and the error is re-raised.
  let subxOldCtx = CurrentMemoryContext
  let subxOldOwner = CurrentResourceOwner
  BeginInternalSubTransaction(nil)
  discard subxMemoryContextSwitchTo(subxOldCtx)
  try:
    body
    ReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
  except CatchableError as e:
    RollbackAndReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
    raise e
  except Defect as e:
    RollbackAndReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
    raise e

template savepoint*(body: untyped, onError: untyped) =
  ## Executes body inside an isolated subtransaction.
  ## If an error occurs, the subtransaction is rolled back, the error is caught,
  ## and onError is invoked with `err` injected, allowing parent transactions
  ## (or batch loops) to continue undisturbed.
  let subxOldCtx = CurrentMemoryContext
  let subxOldOwner = CurrentResourceOwner
  BeginInternalSubTransaction(nil)
  discard subxMemoryContextSwitchTo(subxOldCtx)
  var caughtEx: ref CatchableError = nil
  try:
    body
    ReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
  except CatchableError as e:
    RollbackAndReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
    caughtEx = e
  except Defect as e:
    RollbackAndReleaseCurrentSubTransaction()
    discard subxMemoryContextSwitchTo(subxOldCtx)
    CurrentResourceOwner = subxOldOwner
    caughtEx = (ref CatchableError)(msg: e.msg)

  if caughtEx != nil:
    let err {.inject.} = caughtEx
    onError

proc execute*(query: ExecutableQuery): int {.discardable, tags: [
    DbWriteEffect].} =
  ## Alias for .run()
  run(query)

# =============================================================================
# Stream Helpers & Reducers
# =============================================================================

proc firstOption*[T](items: openArray[T]): Option[T] =
  ## Returns the first item as an Option or none
  if items.len > 0: some(items[0]) else: none(T)

proc toTable*[T, K, V](items: openArray[T], keySelector: proc(
    x: T): K {.closure.}, valSelector: proc(x: T): V {.closure.}): Table[K,
    V] {.effectsOf: keySelector, effectsOf: valSelector.} =
  ## Transforms a collection of items into a key-value Table
  result = initTable[K, V]()
  for item in items:
    result[keySelector(item)] = valSelector(item)

proc any*[T](items: openArray[T], predicate: proc(
    x: T): bool {.closure.}): bool {.effectsOf: predicate.} =
  ## Returns true if any item matches the predicate
  for item in items:
    if predicate(item): return true
  return false

proc all*[T](items: openArray[T], predicate: proc(
    x: T): bool {.closure.}): bool {.effectsOf: predicate.} =
  ## Returns true if all items match the predicate
  for item in items:
    if not predicate(item): return false
  return true

# =============================================================================
# Direct Object Schema & Entity Operations via SPI
# =============================================================================

proc spiCreateTableFrom*[T: object](tableName: string = "",
    ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [
    DbWriteEffect].} =
  ## Inspects properties of object type T, generates CREATE TABLE DDL, and executes it via SPI
  let ddl = createTableFromType[T](tableName, ifNotExists, primaryKey)
  validateNoNullBytes(ddl)
  var ret = 0
  withSpiConnection(didConn, callerContext):
    pgTry:
      ret = int(pgxSpiExecute(const_string(ddl), false, 0))
    raiseIfSpiError(cint(ret), "SPI_execute")
  return ret

proc spiCreateTableFrom*[T: object](obj: T, tableName: string = "",
    ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [
    DbWriteEffect].} =
  ## Inspects properties of an object instance, generates CREATE TABLE DDL, and executes it via SPI
  spiCreateTableFrom[T](tableName, ifNotExists, primaryKey)

proc spiCreateTableFrom*[T: object](t: typedesc[T], tableName: string = "",
    ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [
    DbWriteEffect].} =
  ## Inspects properties of a typedesc[T], generates CREATE TABLE DDL, and executes it via SPI
  spiCreateTableFrom[T](tableName, ifNotExists, primaryKey)

proc spiInsertFrom*[T: object](obj: T, tableName: string = ""): int {.tags: [
    DbWriteEffect].} =
  ## Inspects object instance, generates parameterized INSERT statement, and executes it via SPI
  pgxMarkDbWrite()
  let q = insertFrom(obj, tableName)
  let pq = toParameterizedSql(q)
  validateNoNullBytes(pq.sql)
  var ret = 0
  withSpiConnection(didConn, callerContext):
    ret = int(execSpiQuery(pq.sql, pq.params, false, 0, callerContext))
    if not didConn and SPI_tuptable != nil:
      pgxSpiFreetuptableIfSet()
  return ret

proc spiInsertManyFrom*[T: object](objs: openArray[T],
    tableName: string = ""): int {.tags: [DbWriteEffect].} =
  ## Inspects collection of object instances, generates parameterized multi-row bulk INSERT, and executes via SPI.
  ## Returns 0 immediately if sequence is empty.
  if objs.len == 0: return 0
  pgxMarkDbWrite()
  let q = insertManyFrom(objs, tableName)
  let pq = toParameterizedSql(q)
  validateNoNullBytes(pq.sql)
  var ret = 0
  withSpiConnection(didConn, callerContext):
    ret = int(execSpiQuery(pq.sql, pq.params, false, 0, callerContext))
    if not didConn and SPI_tuptable != nil:
      pgxSpiFreetuptableIfSet()
  return ret

proc spiInsertFrom*[T: object](objs: openArray[T],
    tableName: string = ""): int {.tags: [DbWriteEffect], inline.} =
  ## Overload of spiInsertFrom accepting openArray[T]
  spiInsertManyFrom[T](objs, tableName)
