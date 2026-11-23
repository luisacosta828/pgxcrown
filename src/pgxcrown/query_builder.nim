## =============================================================================
## Type-Safe Step Builder Pattern for PostgreSQL Queries.
## Provides zero-string column DX, automatic SQL injection immunity,
## Common Table Expressions (CTEs), Window Functions, Lateral Joins,
## PostgreSQL UPSERT (ON CONFLICT), Set Operations, and Infix `as` Sugar.
## =============================================================================

import std/[strutils, sequtils, tables, macros, options, json, typetraits, math]
export json

# =============================================================================
# 1. Parameter Types & Safe Value Encoding (SQL Injection Defense)
# =============================================================================
proc sanitizeLiteralString*(s: string): string =
  ## Strips null bytes and escapes single quotes
  var clean = newStringOfCap(s.len)
  for ch in s:
    if ch != '\0':
      if ch == '\'':
        clean.add("''")
      else:
        clean.add(ch)
  clean

proc quoteLiteral*(s: string): string =
  ## Safely escapes and quotes single quotes in string literals ('O''Reilly'),
  ## and strips null bytes to protect against C string poisoning.
  "'" & sanitizeLiteralString(s) & "'"

proc sanitizeIdentifierString*(s: string): string =
  ## Strips null bytes and escapes double quotes
  var clean = newStringOfCap(s.len)
  for ch in s:
    if ch != '\0':
      if ch == '"':
        clean.add("\"\"")
      else:
        clean.add(ch)
  clean

proc quoteIdent*(s: string, splitQualified: bool = false): string =
  ## Safely quotes a PostgreSQL table or column identifier,
  ## and strips null bytes to prevent identifier injection.
  ## If splitQualified is true, dots are treated as namespace separators (e.g. "schema"."table").
  if s.len == 0: return ""
  if s == "*": return "*"
  if splitQualified and "." in s:
    var parts = s.split('.')
    for i in 0 ..< parts.len:
      if parts[i] != "*": parts[i] = "\"" & sanitizeIdentifierString(parts[i]) & "\""
    return parts.join(".")
  return "\"" & sanitizeIdentifierString(s) & "\""

proc quoteQualifiedIdent*(s: string): string {.inline.} =
  quoteIdent(s, splitQualified = true)

type
  BoundParamKind* = enum
    bpNull
    bpBool
    bpInt2
    bpInt4
    bpInt8
    bpFloat4
    bpFloat8
    bpText
    bpJsonb
    bpBytea
    bpUuid
    bpDate
    bpTimestamp
    bpTimestampTz
    bpInterval
    bpNumeric
    bpTextArray
    bpInt4Array
    bpInt8Array
    bpFloat8Array
    bpBoolArray

  BoundParam* = object
    case kind*: BoundParamKind
    of bpNull:
      nullOidHint*: uint32
    of bpBool:
      boolVal*: bool
    of bpInt2:
      int2Val*: int16
    of bpInt4:
      int4Val*: int32
    of bpInt8:
      int8Val*: int64
    of bpFloat4:
      float4Val*: float32
    of bpFloat8:
      float8Val*: float64
    of bpText:
      textVal*: string
    of bpJsonb:
      jsonbVal*: JsonNode
    of bpBytea:
      byteaVal*: seq[byte]
    of bpUuid:
      uuidBytes*: array[16, uint8]
    of bpDate:
      dateDays*: int32
    of bpTimestamp:
      tsUsec*: int64
    of bpTimestampTz:
      tstzUsec*: int64
    of bpInterval:
      ivUsec*: int64
      ivDays*: int32
      ivMonths*: int32
    of bpNumeric:
      numericLit*: string
    of bpTextArray:
      textArr*: seq[string]
    of bpInt4Array:
      int4Arr*: seq[int32]
    of bpInt8Array:
      int8Arr*: seq[int64]
    of bpFloat8Array:
      float8Arr*: seq[float64]
    of bpBoolArray:
      boolArr*: seq[bool]

  ParameterizedQuery* = object
    sql*: string
    params*: seq[BoundParam]

  SqlChunk* = object
    text*: string
    paramIdx*: int # -1 => literal SQL `text`, >= 0 => placeholder for `params[paramIdx]`

  SqlFrag* = object
    chunks*: seq[SqlChunk]
    params*: seq[BoundParam]

  RawSql* = distinct string
  SqlIdent* = distinct string
  SqlExpr* = object
    sql*: string
    frag*: SqlFrag

proc litFrag*(s: string): SqlFrag {.inline.} =
  if s.len == 0:
    return SqlFrag()
  SqlFrag(chunks: @[SqlChunk(text: s, paramIdx: -1)], params: @[])

proc paramFrag*(p: BoundParam): SqlFrag {.inline.} =
  SqlFrag(chunks: @[SqlChunk(paramIdx: 0)], params: @[p])

proc isEmptyFrag*(f: SqlFrag): bool {.inline.} =
  f.chunks.len == 0 and f.params.len == 0

proc addLit*(dst: var SqlFrag, s: string) {.inline.} =
  if s.len == 0:
    return
  if dst.chunks.len > 0 and dst.chunks[^1].paramIdx < 0:
    dst.chunks[^1].text.add(s)
  else:
    dst.chunks.add(SqlChunk(text: s, paramIdx: -1))

proc addFrag*(dst: var SqlFrag, src: SqlFrag) =
  let base = dst.params.len
  for p in src.params:
    dst.params.add(p)
  for ch in src.chunks:
    if ch.paramIdx < 0:
      dst.addLit(ch.text)
    else:
      dst.chunks.add(SqlChunk(paramIdx: base + ch.paramIdx))

proc joinFrags*(frags: openArray[SqlFrag], sep: string): SqlFrag =
  for i, f in frags:
    if i > 0:
      result.addLit(sep)
    result.addFrag(f)

proc renderParameterized*(f: SqlFrag): ParameterizedQuery =
  var sql = newStringOfCap(128)
  for ch in f.chunks:
    if ch.paramIdx < 0:
      sql.add(ch.text)
    else:
      sql.add('$')
      sql.add($(ch.paramIdx + 1))
  if '\0' in sql:
    raise newException(ValueError, "SQL query contains prohibited null byte character (SQL injection defense)")
  ParameterizedQuery(sql: sql, params: f.params)

proc effectiveFrag*(e: SqlExpr): SqlFrag {.inline.} =
  if not isEmptyFrag(e.frag): e.frag else: litFrag(e.sql)

proc params*(e: SqlExpr): seq[BoundParam] {.inline.} = e.frag.params

proc raw*(s: string): RawSql = RawSql(s)
proc `$`*(r: RawSql): string = string(r)
proc `$`*(e: SqlExpr): string = e.sql

proc formatPgFloat*(v: float64): string {.inline.} =
  case classify(v)
  of fcNan: "'NaN'::float8"
  of fcInf: "'Infinity'::float8"
  of fcNegInf: "'-Infinity'::float8"
  else: $v

proc isDatumOrContainsDatum*[T](): bool {.compileTime.} =
  when typetraits.name(T) == "Datum":
    true
  elif T is Option:
    isDatumOrContainsDatum[typeof(default(T).get)]()
  elif T is seq:
    isDatumOrContainsDatum[typeof(default(T)[0])]()
  elif T is distinct:
    isDatumOrContainsDatum[distinctBase(T, false)]()
  else:
    false

proc formatSqlValue*[T](val: T): string =
  ## Safely serializes a Nim value into a SQL literal for queries, INSERT/UPDATE and VALUES statements
  when isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum (or container of Datum) cannot be formatted as a SQL literal value; convert it to a typed Nim value first.".}
  elif T is RawSql:
    string(val)
  elif T is SqlExpr:
    val.sql
  elif T is distinct:
    when T is SqlIdent:
      {.error: "SqlIdent represents a SQL identifier, not a SQL literal value; use ColumnRef, Select, GroupBy, OrderBy, or quoteIdent instead.".}
    else:
      formatSqlValue(val.distinctBase)
  elif T is int or T is int32 or T is int64 or T is int16 or T is int8 or T is byte:
    $val
  elif T is uint or T is uint32 or T is uint64 or T is uint16 or T is uint8:
    $val
  elif T is float or T is float64 or T is float32:
    formatPgFloat(float64(val))
  elif T is bool:
    if val: "TRUE" else: "FALSE"
  elif T is string or T is cstring:
    quoteLiteral($val)
  elif T is char:
    quoteLiteral($val)
  elif T is JsonNode:
    if val.isNil or val.kind == JNull:
      "NULL"
    else:
      quoteLiteral($val)
  elif T is Option:
    if val.isSome:
      formatSqlValue(val.get)
    else:
      "NULL"
  elif T is seq:
    when typeof(val[0]) is string or typeof(val[0]) is cstring:
      if val.len == 0: "ARRAY[]::text[]"
      else: "ARRAY[" & val.mapIt(quoteLiteral($it)).join(", ") & "]"
    elif typeof(val[0]) is int or typeof(val[0]) is int32:
      if val.len == 0: "ARRAY[]::integer[]"
      else: "ARRAY[" & val.mapIt($it).join(", ") & "]"
    elif typeof(val[0]) is int64:
      if val.len == 0: "ARRAY[]::bigint[]"
      else: "ARRAY[" & val.mapIt($it).join(", ") & "]"
    elif typeof(val[0]) is int16 or typeof(val[0]) is int8 or typeof(val[0]) is byte:
      if val.len == 0: "ARRAY[]::smallint[]"
      else: "ARRAY[" & val.mapIt($it).join(", ") & "]"
    elif typeof(val[0]) is uint or typeof(val[0]) is uint32 or typeof(val[0]) is uint64 or typeof(val[0]) is uint16 or typeof(val[0]) is uint8:
      if val.len == 0: "ARRAY[]::bigint[]"
      else: "ARRAY[" & val.mapIt($it).join(", ") & "]"
    elif typeof(val[0]) is float or typeof(val[0]) is float64 or typeof(val[0]) is float32:
      if val.len == 0: "ARRAY[]::double precision[]"
      else: "ARRAY[" & val.mapIt(formatPgFloat(float64(it))).join(", ") & "]"
    elif typeof(val[0]) is bool:
      if val.len == 0: "ARRAY[]::boolean[]"
      else: "ARRAY[" & val.mapIt(if it: "TRUE" else: "FALSE").join(", ") & "]"
    elif typeof(val[0]) is JsonNode:
      if val.len == 0: "ARRAY[]::jsonb[]"
      else: "ARRAY[" & val.mapIt(if it.isNil or it.kind == JNull: "NULL" else: quoteLiteral($it)).join(", ") & "]::jsonb[]"
    elif typeof(val[0]) is distinct:
      when typeof(val[0]) is SqlIdent:
        {.error: "seq[SqlIdent] cannot be formatted as a SQL literal ARRAY; pass identifier columns to Select, GroupBy, or OrderBy instead.".}
      elif typeof(val[0]) is RawSql:
        if val.len == 0: "ARRAY[]::text[]"
        else: "ARRAY[" & val.mapIt(string(it)).join(", ") & "]"
      else:
        if val.len == 0: formatSqlValue(newSeq[distinctBase(typeof(val[0]))]())
        else: formatSqlValue(val.mapIt(it.distinctBase))
    elif typeof(val[0]) is enum:
      if val.len == 0: "ARRAY[]::text[]"
      else: "ARRAY[" & val.mapIt(quoteLiteral($it)).join(", ") & "]"
    elif typetraits.name(typeof(val[0])) in ["PgUuid", "PgBytea", "PgDate", "PgTimestamp", "PgTimestampTz", "PgInterval"]:
      let sqlCast = case typetraits.name(typeof(val[0]))
        of "PgUuid": "::uuid[]"
        of "PgBytea": "::bytea[]"
        of "PgDate": "::date[]"
        of "PgTimestamp": "::timestamp[]"
        of "PgTimestampTz": "::timestamptz[]"
        of "PgInterval": "::interval[]"
        else: "::text[]"
      if val.len == 0: "ARRAY[]" & sqlCast
      else: "ARRAY[" & val.mapIt(quoteLiteral($it)).join(", ") & "]" & sqlCast
    elif typetraits.name(typeof(val[0])) == "PgNumeric":
      if val.len == 0: "ARRAY[]::numeric[]"
      else: "ARRAY[" & val.mapIt(quoteLiteral($it) & "::numeric").join(", ") & "]"
    elif typetraits.name(typeof(val[0])) == "PgText":
      if val.len == 0: "ARRAY[]::text[]"
      else: "ARRAY[" & val.mapIt(quoteLiteral($it)).join(", ") & "]"
    else:
      quoteLiteral($val)
  else:
    quoteLiteral($val)

type
  ParamKind* = enum
    pkInt, pkFloat, pkString, pkBool, pkNull, pkJson, pkRaw

  QueryParam* = object
    hasBound*: bool
    bound*: BoundParam
    rawFrag*: SqlFrag
    case kind*: ParamKind
    of pkInt: intVal*: int64
    of pkFloat: floatVal*: float64
    of pkString: strVal*: string
    of pkBool: boolVal*: bool
    of pkNull: discard
    of pkJson: jsonVal*: JsonNode
    of pkRaw: rawVal*: string

proc intToBoundParam(v: int64): BoundParam {.inline.} =
  if v >= int64(low(int32)) and v <= int64(high(int32)):
    BoundParam(kind: bpInt4, int4Val: int32(v))
  else:
    BoundParam(kind: bpInt8, int8Val: v)

proc boundNullOidHint*[T](): uint32 =
  when T is bool: 16'u32
  elif T is int16 or T is int8: 21'u32
  elif T is int or T is int32 or T is cint: 23'u32
  elif T is int64 or T is clonglong: 20'u32
  elif T is uint8 or T is byte or T is uint16: 23'u32
  elif T is uint or T is uint32 or T is cuint: 23'u32
  elif T is uint64: 20'u32
  elif T is float32 or T is cfloat: 700'u32
  elif T is float or T is float64 or T is cdouble: 701'u32
  elif T is string or T is cstring or T is char: 25'u32
  elif T is JsonNode: 3802'u32
  elif typetraits.name(T) == "PgBytea": 17'u32
  elif typetraits.name(T) == "PgUuid": 2950'u32
  elif typetraits.name(T) == "PgDate": 1082'u32
  elif typetraits.name(T) == "PgTimestamp": 1114'u32
  elif typetraits.name(T) == "PgTimestampTz": 1184'u32
  elif typetraits.name(T) == "PgInterval": 1186'u32
  elif typetraits.name(T) == "PgNumeric": 1700'u32
  elif typetraits.name(T) == "PgText": 25'u32
  elif T is distinct:
    boundNullOidHint[distinctBase(T)]()
  elif T is enum:
    705'u32 # UNKNOWNOID: allows PostgreSQL to infer target enum column type
  elif T is seq:
    type ElemT = typeof(default(T)[0])
    when ElemT is string or ElemT is enum or typetraits.name(ElemT) == "PgText": 1009'u32
    elif ElemT is int or ElemT is int32: 1007'u32
    elif ElemT is int64: 1016'u32
    elif ElemT is float or ElemT is float64: 1022'u32
    elif ElemT is bool: 1000'u32
    else: 0'u32
  elif typetraits.name(T).startsWith("PgVector["):
    let tn = typetraits.name(T)
    if "int32" in tn or "int]" in tn: 1007'u32
    elif "int64" in tn: 1016'u32
    elif "float64" in tn or "float]" in tn: 1022'u32
    elif "bool" in tn: 1000'u32
    else: 0'u32
  else:
    0'u32

proc seqToBoundParam[ElemT](s: seq[ElemT]): tuple[ok: bool, param: BoundParam] =
  when ElemT is string or ElemT is cstring:
    var arr = newSeq[string](s.len)
    for i in 0 ..< s.len:
      arr[i] = $s[i]
    (true, BoundParam(kind: bpTextArray, textArr: arr))
  elif ElemT is int32:
    (true, BoundParam(kind: bpInt4Array, int4Arr: s))
  elif ElemT is int:
    var fits32 = true
    for x in s:
      if int64(x) < int64(low(int32)) or int64(x) > int64(high(int32)):
        fits32 = false
        break
    if fits32:
      var arr = newSeq[int32](s.len)
      for i in 0 ..< s.len: arr[i] = int32(s[i])
      (true, BoundParam(kind: bpInt4Array, int4Arr: arr))
    else:
      var arr = newSeq[int64](s.len)
      for i in 0 ..< s.len: arr[i] = int64(s[i])
      (true, BoundParam(kind: bpInt8Array, int8Arr: arr))
  elif ElemT is int64:
    (true, BoundParam(kind: bpInt8Array, int8Arr: s))
  elif ElemT is float64 or ElemT is float:
    var arr = newSeq[float64](s.len)
    for i in 0 ..< s.len: arr[i] = float64(s[i])
    (true, BoundParam(kind: bpFloat8Array, float8Arr: arr))
  elif ElemT is bool:
    (true, BoundParam(kind: bpBoolArray, boolArr: s))
  elif ElemT is enum:
    var arr = newSeq[string](s.len)
    for i in 0 ..< s.len: arr[i] = $s[i]
    (true, BoundParam(kind: bpTextArray, textArr: arr))
  elif typetraits.name(ElemT) == "PgText":
    var arr = newSeq[string](s.len)
    for i in 0 ..< s.len: arr[i] = $s[i]
    (true, BoundParam(kind: bpTextArray, textArr: arr))
  elif ElemT is distinct:
    when ElemT is SqlIdent or ElemT is RawSql:
      (false, BoundParam(kind: bpNull))
    else:
      var baseSeq = newSeq[distinctBase(ElemT)](s.len)
      for i in 0 ..< s.len:
        baseSeq[i] = s[i].distinctBase
      seqToBoundParam(baseSeq)
  else:
    (false, BoundParam(kind: bpNull))

proc toParam*(v: int): QueryParam =
  QueryParam(hasBound: true, bound: intToBoundParam(v.int64), kind: pkInt, intVal: v.int64)
proc toParam*(v: int32): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt4, int4Val: v), kind: pkInt, intVal: v.int64)
proc toParam*(v: int64): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt8, int8Val: v), kind: pkInt, intVal: v)
proc toParam*(v: int16): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt2, int2Val: v), kind: pkInt, intVal: v.int64)
proc toParam*(v: int8): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt2, int2Val: int16(v)), kind: pkInt, intVal: v.int64)
proc toParam*(v: uint): QueryParam =
  let bp = if uint64(v) <= uint64(high(int32)): BoundParam(kind: bpInt4, int4Val: int32(v))
           elif uint64(v) <= uint64(high(int64)): BoundParam(kind: bpInt8, int8Val: int64(v))
           else: BoundParam(kind: bpNumeric, numericLit: $v)
  QueryParam(hasBound: true, bound: bp, kind: pkRaw, rawVal: $v)
proc toParam*(v: uint32): QueryParam =
  let bp = if uint64(v) <= uint64(high(int32)): BoundParam(kind: bpInt4, int4Val: int32(v))
           else: BoundParam(kind: bpInt8, int8Val: int64(v))
  QueryParam(hasBound: true, bound: bp, kind: pkRaw, rawVal: $v)
proc toParam*(v: uint64): QueryParam =
  let bp = if v <= uint64(high(int64)): BoundParam(kind: bpInt8, int8Val: int64(v))
           else: BoundParam(kind: bpNumeric, numericLit: $v)
  QueryParam(hasBound: true, bound: bp, kind: pkRaw, rawVal: $v)
proc toParam*(v: uint16): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt4, int4Val: int32(v)), kind: pkRaw, rawVal: $v)
proc toParam*(v: uint8): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpInt4, int4Val: int32(v)), kind: pkRaw, rawVal: $v)
proc toParam*(v: float): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpFloat8, float8Val: v), kind: pkFloat, floatVal: v)
proc toParam*(v: float32): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpFloat4, float4Val: v), kind: pkFloat, floatVal: v.float64)
proc toParam*(v: string): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpText, textVal: v), kind: pkString, strVal: v)
proc toParam*(v: cstring): QueryParam =
  if v == nil:
    QueryParam(hasBound: true, bound: BoundParam(kind: bpNull, nullOidHint: 25'u32), kind: pkNull)
  else:
    let s = $v
    QueryParam(hasBound: true, bound: BoundParam(kind: bpText, textVal: s), kind: pkString, strVal: s)
proc toParam*(v: char): QueryParam =
  let s = $v
  QueryParam(hasBound: true, bound: BoundParam(kind: bpText, textVal: s), kind: pkString, strVal: s)
proc toParam*(v: bool): QueryParam =
  QueryParam(hasBound: true, bound: BoundParam(kind: bpBool, boolVal: v), kind: pkBool, boolVal: v)
proc toParam*(v: JsonNode): QueryParam =
  if v.isNil or v.kind == JNull:
    QueryParam(hasBound: true, bound: BoundParam(kind: bpNull, nullOidHint: 3802'u32), kind: pkNull)
  else:
    QueryParam(hasBound: true, bound: BoundParam(kind: bpJsonb, jsonbVal: v), kind: pkJson, jsonVal: v)
proc toParam*(r: RawSql): QueryParam = QueryParam(kind: pkRaw, rawVal: string(r))
proc toParam*(e: SqlExpr): QueryParam = QueryParam(rawFrag: effectiveFrag(e), kind: pkRaw, rawVal: e.sql)
proc toParam*(p: QueryParam): QueryParam = p
proc toParam*[T](o: Option[T]): QueryParam =
  mixin toParam
  when isDatumOrContainsDatum[T]():
    {.error: "Option[Datum] cannot be passed as a QueryParam; convert Datum to a typed Nim value first.".}
  else:
    if o.isSome: toParam(o.get)
    else: QueryParam(hasBound: true, bound: BoundParam(kind: bpNull, nullOidHint: boundNullOidHint[T]()), kind: pkNull)
proc toParam*[T](s: seq[T]): QueryParam =
  let bp = seqToBoundParam(s)
  QueryParam(hasBound: bp.ok, bound: bp.param, kind: pkRaw, rawVal: formatSqlValue(s))
proc toParam*[T: distinct](v: T): QueryParam =
  mixin toParam
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a QueryParam literal value; pass ColumnRef/ColumnExpr or a string.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be passed as a QueryParam; convert it to a typed Nim value (e.g. int64, string, PgText, float64) first.".}
  else:
    toParam(v.distinctBase)
proc toParam*[T: enum](v: T): QueryParam =
  let s = $v
  QueryParam(hasBound: true, bound: BoundParam(kind: bpText, textVal: s), kind: pkString, strVal: s)

converter toQueryParam*(v: int): QueryParam = toParam(v)
converter toQueryParam*(v: int32): QueryParam = toParam(v)
converter toQueryParam*(v: int64): QueryParam = toParam(v)
converter toQueryParam*(v: int16): QueryParam = toParam(v)
converter toQueryParam*(v: int8): QueryParam = toParam(v)
converter toQueryParam*(v: uint): QueryParam = toParam(v)
converter toQueryParam*(v: uint32): QueryParam = toParam(v)
converter toQueryParam*(v: uint64): QueryParam = toParam(v)
converter toQueryParam*(v: uint16): QueryParam = toParam(v)
converter toQueryParam*(v: uint8): QueryParam = toParam(v)
converter toQueryParam*(v: float): QueryParam = toParam(v)
converter toQueryParam*(v: float32): QueryParam = toParam(v)
converter toQueryParam*(v: bool): QueryParam = toParam(v)
converter toQueryParam*(v: string): QueryParam = toParam(v)
converter toQueryParam*(v: cstring): QueryParam = toParam(v)
converter toQueryParam*(v: char): QueryParam = toParam(v)
converter toQueryParam*(v: JsonNode): QueryParam = toParam(v)
converter toQueryParam*(r: RawSql): QueryParam = toParam(r)
converter toQueryParam*(e: SqlExpr): QueryParam = toParam(e)
converter toQueryParam*[T](s: seq[T]): QueryParam = toParam(s)
converter toQueryParam*[T](o: Option[T]): QueryParam = toParam(o)
converter toQueryParam*[T: distinct](v: T): QueryParam =
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a QueryParam literal value.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be implicitly converted to QueryParam; convert it to a typed Nim value first.".}
  else:
    toParam(v)
converter toQueryParam*[T: enum](v: T): QueryParam = toParam(v)

proc `$`*(p: QueryParam): string =
  case p.kind
  of pkInt: $p.intVal
  of pkFloat: formatPgFloat(p.floatVal)
  of pkString: quoteLiteral(p.strVal)
  of pkBool: (if p.boolVal: "TRUE" else: "FALSE")
  of pkNull: "NULL"
  of pkJson: (if p.jsonVal.isNil or p.jsonVal.kind == JNull: "NULL" else: quoteLiteral($p.jsonVal))
  of pkRaw: p.rawVal

proc toQueryParamEx*[T](val: T): QueryParam =
  ## Converts any supported Nim or pgxcrown value into a QueryParam carrying a binary BoundParam.
  mixin toParam
  when isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be passed as a QueryParam; convert it to a typed Nim value first.".}
  elif T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a QueryParam literal value.".}
  elif T is QueryParam:
    val
  elif T is RawSql or T is SqlExpr:
    toParam(val)
  elif T is Option:
    type ElemT = typeof(val.get)
    if val.isSome:
      toQueryParamEx(val.get)
    else:
      QueryParam(hasBound: true, bound: BoundParam(kind: bpNull, nullOidHint: boundNullOidHint[ElemT]()), kind: pkNull)
  elif typetraits.name(T) == "PgUuid":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpUuid, uuidBytes: val.bytes), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgDate":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpDate, dateDays: val.days), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgTimestamp":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpTimestamp, tsUsec: val.usec), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgTimestampTz":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpTimestampTz, tstzUsec: val.usec), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgInterval":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpInterval, ivUsec: val.usec, ivDays: val.days, ivMonths: val.months), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgBytea":
    QueryParam(hasBound: true, bound: BoundParam(kind: bpBytea, byteaVal: toBytes(val)), kind: pkString, strVal: $val)
  elif typetraits.name(T) == "PgNumeric":
    let s = $val
    QueryParam(hasBound: true, bound: BoundParam(kind: bpNumeric, numericLit: s), kind: pkRaw, rawVal: quoteLiteral(s) & "::numeric")
  elif typetraits.name(T) == "PgText":
    let s = $val
    QueryParam(hasBound: true, bound: BoundParam(kind: bpText, textVal: s), kind: pkString, strVal: s)
  elif typetraits.name(T).startsWith("PgVector["):
    toQueryParamEx(@val)
  elif T is distinct:
    toQueryParamEx(val.distinctBase)
  elif T is seq:
    let bp = seqToBoundParam(val)
    QueryParam(hasBound: bp.ok, bound: bp.param, kind: pkRaw, rawVal: formatSqlValue(val))
  else:
    toParam(val)

proc toBoundParam*[T](v: T): BoundParam =
  ## Converts any supported Nim or pgxcrown value directly into a BoundParam for prepared plans/cursors.
  when T is BoundParam:
    v
  else:
    let qp = toQueryParamEx(v)
    if qp.hasBound:
      qp.bound
    else:
      case qp.kind
      of pkNull: BoundParam(kind: bpNull)
      of pkInt: intToBoundParam(qp.intVal)
      of pkFloat: BoundParam(kind: bpFloat8, float8Val: qp.floatVal)
      of pkString: BoundParam(kind: bpText, textVal: qp.strVal)
      of pkBool: BoundParam(kind: bpBool, boolVal: qp.boolVal)
      of pkJson:
        if qp.jsonVal.isNil or qp.jsonVal.kind == JNull:
          BoundParam(kind: bpNull, nullOidHint: 3802'u32)
        else:
          BoundParam(kind: bpJsonb, jsonbVal: qp.jsonVal)
      of pkRaw:
        BoundParam(kind: bpText, textVal: qp.rawVal)

proc boundNull*(oidHint: uint32 = 0'u32): BoundParam {.inline.} =
  BoundParam(kind: bpNull, nullOidHint: oidHint)

proc toFrag*(p: QueryParam): SqlFrag {.inline.} =
  if p.hasBound:
    paramFrag(p.bound)
  elif not isEmptyFrag(p.rawFrag):
    p.rawFrag
  else:
    litFrag($p)

# =============================================================================
# 2. Table & Column Identifiers (Zero-string Table Proxies)
# =============================================================================
type
  TableRef* = object
    rawTable*: string
    rawAlias*: string

  ColumnRef* = object
    rawTable*: string
    rawAlias*: string
    rawCol*: string

proc table*(name: string, alias: string = ""): TableRef =
  ## Creates a Table Proxy for zero-string column access (e.g. `let u = table("users", "u")`)
  TableRef(rawTable: sanitizeIdentifierString(name), rawAlias: sanitizeIdentifierString(alias))

template `.`*(t: TableRef, field: untyped): ColumnRef =
  ## Dot-access for table proxies: `u.name` -> ColumnRef(table: "u", col: "name")
  ColumnRef(rawTable: t.rawTable, rawAlias: t.rawAlias, rawCol: astToStr(field))

proc sqlIdent*(s: string): SqlIdent = SqlIdent(s)
proc sqlId*(s: string): SqlIdent = SqlIdent(s)
proc ident*(s: string): ColumnRef = ColumnRef(rawCol: s)

proc `$`*(c: ColumnRef): string =
  let prefix = if c.rawAlias.len > 0: c.rawAlias else: c.rawTable
  if prefix.len > 0:
    quoteIdent(prefix) & "." & quoteIdent(c.rawCol)
  else:
    quoteIdent(c.rawCol)

proc `$`*(id: SqlIdent): string = quoteIdent(string(id))

# =============================================================================
# 3. Expressions, Window Functions, and Case Statements
# =============================================================================
type
  ColumnExpr* = object
    expr*: string
    alias*: string
    frag*: SqlFrag

  WindowClause* = object
    partitionCols*: seq[string]
    orderCols*: seq[string]

  CaseWhenBuilder* = object
    whens*: seq[(string, string)] # (condition, result)
    elseExpr*: string
    whenFrags*: seq[(SqlFrag, SqlFrag)]
    elseFrag*: SqlFrag

proc effectiveFrag*(c: ColumnExpr): SqlFrag {.inline.} =
  if not isEmptyFrag(c.frag): c.frag else: litFrag(c.expr)

proc binFrag(prefix: string, rhs: SqlFrag): SqlFrag {.inline.} =
  result = litFrag(prefix)
  addFrag(result, rhs)

proc makeCmpExpr(lhsSql, op: string, p: QueryParam, nullOpSql: string): SqlExpr {.inline.} =
  if p.kind == pkNull:
    let s = lhsSql & nullOpSql
    SqlExpr(sql: s, frag: litFrag(s))
  else:
    SqlExpr(sql: lhsSql & op & $p, frag: binFrag(lhsSql & op, toFrag(p)))

proc makeValCmpExpr[T](lhsSql, op: string, val: T, nullOpSql: string = ""): SqlExpr {.inline.} =
  let p = toQueryParamEx(val)
  makeCmpExpr(lhsSql, op, p, nullOpSql)

proc makeLikeExpr(lhsSql, op, pattern: string): SqlExpr {.inline.} =
  let p = toParam(pattern)
  SqlExpr(sql: lhsSql & op & $p, frag: binFrag(lhsSql & op, toFrag(p)))

proc makeInListExpr[T](lhsSql: string, neg: bool, items: openArray[T]): SqlExpr =
  if items.len == 0:
    let fallback = if neg: "TRUE" else: "FALSE"
    return SqlExpr(sql: fallback, frag: litFrag(fallback))
  var sqlParts = newSeq[string](items.len)
  var frags = newSeq[SqlFrag](items.len)
  for i, it in items:
    let p = toQueryParamEx(it)
    sqlParts[i] = $p
    frags[i] = toFrag(p)
  let kw = if neg: " NOT IN (" else: " IN ("
  var f = litFrag(lhsSql & kw)
  addFrag(f, joinFrags(frags, ", "))
  addLit(f, ")")
  SqlExpr(sql: lhsSql & kw & sqlParts.join(", ") & ")", frag: f)

proc makeBetweenExpr[T](lhsSql: string, minVal, maxVal: T): SqlExpr =
  let pMin = toQueryParamEx(minVal)
  let pMax = toQueryParamEx(maxVal)
  var f = litFrag(lhsSql & " BETWEEN ")
  addFrag(f, toFrag(pMin))
  addLit(f, " AND ")
  addFrag(f, toFrag(pMax))
  SqlExpr(sql: lhsSql & " BETWEEN " & $pMin & " AND " & $pMax, frag: f)

proc makeJsonContainExpr(lhsSql, op: string, jsonVal: JsonNode): SqlExpr =
  if jsonVal.isNil or jsonVal.kind == JNull:
    SqlExpr(sql: "FALSE", frag: litFrag("FALSE"))
  else:
    let p = toParam(jsonVal)
    SqlExpr(sql: lhsSql & op & quoteLiteral($jsonVal), frag: binFrag(lhsSql & op, toFrag(p)))

proc makeJsonContainRawExpr(lhsSql, op, jsonVal: string): SqlExpr =
  let p = toParam(jsonVal)
  var f = binFrag(lhsSql & op, toFrag(p))
  addLit(f, "::jsonb")
  SqlExpr(sql: lhsSql & op & quoteLiteral(jsonVal), frag: f)

proc makeJsonKeyArrayExpr(lhsSql, op: string, keys: openArray[string]): SqlExpr =
  let quoted = keys.mapIt(quoteLiteral(it)).join(", ")
  var arr = newSeq[string](keys.len)
  for i, k in keys: arr[i] = k
  SqlExpr(
    sql: lhsSql & op & "ARRAY[" & quoted & "]",
    frag: binFrag(lhsSql & op, paramFrag(BoundParam(kind: bpTextArray, textArr: arr)))
  )

when (NimMajor, NimMinor) >= (2, 2):
  {.push warning[InvalidCmpOp]: off.}

# Column to Column comparison (e.g. orders.user_id == users.id)
proc `==`*(a: ColumnRef, b: ColumnRef): SqlExpr =
  let s = $a & " = " & $b
  SqlExpr(sql: s, frag: litFrag(s))
proc `!=`*(a: ColumnRef, b: ColumnRef): SqlExpr =
  let s = $a & " != " & $b
  SqlExpr(sql: s, frag: litFrag(s))

# Column to Value comparison (automatically escaped / parameterized)
proc `==`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: bool): SqlExpr = makeValCmpExpr($c, " = ", val, " IS NULL")
proc `==`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " = ", val, " IS NULL")
proc `==`*[T: not (ColumnRef or ColumnExpr or QueryParam or JsonNode)](c: ColumnRef, val: T): SqlExpr =
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a value literal; pass ColumnRef/ColumnExpr or a string.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be compared against a SQL ColumnRef; convert it to a typed Nim value first.".}
  else:
    makeCmpExpr($c, " = ", toQueryParamEx(val), " IS NULL")
proc `==`*(c: ColumnRef, val: JsonNode): SqlExpr =
  if val.isNil or val.kind == JNull:
    let s = $c & " IS NULL"
    SqlExpr(sql: s, frag: litFrag(s))
  else:
    let p = toParam(val)
    SqlExpr(sql: $c & " = " & quoteLiteral($val), frag: binFrag($c & " = ", toFrag(p)))

proc `!=`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: bool): SqlExpr = makeValCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " != ", val, " IS NOT NULL")
proc `!=`*[T: not (ColumnRef or ColumnExpr or QueryParam or JsonNode)](c: ColumnRef, val: T): SqlExpr =
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a value literal; pass ColumnRef/ColumnExpr or a string.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be compared against a SQL ColumnRef; convert it to a typed Nim value first.".}
  else:
    makeCmpExpr($c, " != ", toQueryParamEx(val), " IS NOT NULL")
proc `!=`*(c: ColumnRef, val: JsonNode): SqlExpr =
  if val.isNil or val.kind == JNull:
    let s = $c & " IS NOT NULL"
    SqlExpr(sql: s, frag: litFrag(s))
  else:
    let p = toParam(val)
    SqlExpr(sql: $c & " != " & quoteLiteral($val), frag: binFrag($c & " != ", toFrag(p)))

proc `>=`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " >= ", val)
proc `>=`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " >= ", val)
proc `>=`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " >= ", val)
proc `>=`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " >= ", val)
proc `>=`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " >= ", val)
proc `>=`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " >= ", val, " IS NULL")

proc `<=`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " <= ", val)
proc `<=`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " <= ", val)
proc `<=`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " <= ", val)
proc `<=`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " <= ", val)
proc `<=`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " <= ", val)
proc `<=`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " <= ", val, " IS NULL")

proc `>`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " > ", val)
proc `>`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " > ", val)
proc `>`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " > ", val)
proc `>`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " > ", val)
proc `>`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " > ", val)
proc `>`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " > ", val, " IS NULL")

proc `<`*(c: ColumnRef, val: int): SqlExpr = makeValCmpExpr($c, " < ", val)
proc `<`*(c: ColumnRef, val: int32): SqlExpr = makeValCmpExpr($c, " < ", val)
proc `<`*(c: ColumnRef, val: int64): SqlExpr = makeValCmpExpr($c, " < ", val)
proc `<`*(c: ColumnRef, val: float): SqlExpr = makeValCmpExpr($c, " < ", val)
proc `<`*(c: ColumnRef, val: string): SqlExpr = makeValCmpExpr($c, " < ", val)
proc `<`*(c: ColumnRef, val: QueryParam): SqlExpr = makeCmpExpr($c, " < ", val, " IS NULL")

# String helper operators
proc like*(c: ColumnRef, pattern: string): SqlExpr = makeLikeExpr($c, " LIKE ", pattern)
proc ilike*(c: ColumnRef, pattern: string): SqlExpr = makeLikeExpr($c, " ILIKE ", pattern)
proc notLike*(c: ColumnRef, pattern: string): SqlExpr = makeLikeExpr($c, " NOT LIKE ", pattern)
proc notIlike*(c: ColumnRef, pattern: string): SqlExpr = makeLikeExpr($c, " NOT ILIKE ", pattern)

# NULL helpers
proc isNull*(c: ColumnRef): SqlExpr =
  let s = $c & " IS NULL"
  SqlExpr(sql: s, frag: litFrag(s))
proc isNotNull*(c: ColumnRef): SqlExpr =
  let s = $c & " IS NOT NULL"
  SqlExpr(sql: s, frag: litFrag(s))

# IN list helper
proc inList*(c: ColumnRef, items: openArray[string]): SqlExpr = makeInListExpr($c, false, items)
proc inList*(c: ColumnRef, items: openArray[int]): SqlExpr = makeInListExpr($c, false, items)
proc inList*(c: ColumnRef, items: openArray[int32]): SqlExpr = makeInListExpr($c, false, items)
proc inList*(c: ColumnRef, items: openArray[int64]): SqlExpr = makeInListExpr($c, false, items)

proc notInList*(c: ColumnRef, items: openArray[string]): SqlExpr = makeInListExpr($c, true, items)
proc notInList*(c: ColumnRef, items: openArray[int]): SqlExpr = makeInListExpr($c, true, items)

# BETWEEN helper
proc between*(c: ColumnRef, minVal, maxVal: int): SqlExpr = makeBetweenExpr($c, minVal, maxVal)
proc between*(c: ColumnRef, minVal, maxVal: float): SqlExpr = makeBetweenExpr($c, minVal, maxVal)
proc between*(c: ColumnRef, minVal, maxVal: string): SqlExpr = makeBetweenExpr($c, minVal, maxVal)

# ColumnExpr comparisons (for HAVING, JSON extractions, or computed columns)
proc `>`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " > ", val)
proc `>`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " > ", val)
proc `>`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " > ", val)
proc `>`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " > ", val)
proc `>`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " > ", val)

proc `<`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " < ", val)
proc `<`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " < ", val)
proc `<`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " < ", val)
proc `<`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " < ", val)
proc `<`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " < ", val)

proc `>=`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " >= ", val)
proc `>=`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " >= ", val)
proc `>=`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " >= ", val)
proc `>=`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " >= ", val)
proc `>=`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " >= ", val)

proc `<=`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " <= ", val)
proc `<=`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " <= ", val)
proc `<=`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " <= ", val)
proc `<=`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " <= ", val)
proc `<=`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " <= ", val)

proc `==`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: bool): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*(c: ColumnExpr, val: QueryParam): SqlExpr = makeCmpExpr(c.expr, " = ", val, " IS NULL")
proc `==`*[T: not (ColumnRef or ColumnExpr or QueryParam or JsonNode)](c: ColumnExpr, val: T): SqlExpr =
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a value literal; pass ColumnRef/ColumnExpr or a string.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be compared against a SQL ColumnExpr; convert it to a typed Nim value first.".}
  else:
    makeCmpExpr(c.expr, " = ", toQueryParamEx(val), " IS NULL")
proc `==`*(c: ColumnExpr, val: ColumnRef): SqlExpr =
  var f = effectiveFrag(c)
  addLit(f, " = " & $val)
  SqlExpr(sql: c.expr & " = " & $val, frag: f)
proc `==`*(a: ColumnExpr, b: ColumnExpr): SqlExpr =
  var f = effectiveFrag(a)
  addLit(f, " = ")
  addFrag(f, effectiveFrag(b))
  SqlExpr(sql: a.expr & " = " & b.expr, frag: f)
proc `==`*(c: ColumnExpr, val: JsonNode): SqlExpr =
  if val.isNil or val.kind == JNull:
    let s = c.expr & " IS NULL"
    SqlExpr(sql: s, frag: litFrag(s))
  else:
    let p = toParam(val)
    SqlExpr(sql: c.expr & " = " & quoteLiteral($val), frag: binFrag(c.expr & " = ", toFrag(p)))

proc `!=`*(c: ColumnExpr, val: int): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: int32): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: int64): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: float): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: bool): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: string): SqlExpr = makeValCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: QueryParam): SqlExpr = makeCmpExpr(c.expr, " != ", val, " IS NOT NULL")
proc `!=`*[T: not (ColumnRef or ColumnExpr or QueryParam or JsonNode)](c: ColumnExpr, val: T): SqlExpr =
  when T is SqlIdent:
    {.error: "SqlIdent represents a SQL identifier, not a value literal; pass ColumnRef/ColumnExpr or a string.".}
  elif isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be compared against a SQL ColumnExpr; convert it to a typed Nim value first.".}
  else:
    makeCmpExpr(c.expr, " != ", toQueryParamEx(val), " IS NOT NULL")
proc `!=`*(c: ColumnExpr, val: ColumnRef): SqlExpr =
  var f = effectiveFrag(c)
  addLit(f, " != " & $val)
  SqlExpr(sql: c.expr & " != " & $val, frag: f)
proc `!=`*(a: ColumnExpr, b: ColumnExpr): SqlExpr =
  var f = effectiveFrag(a)
  addLit(f, " != ")
  addFrag(f, effectiveFrag(b))
  SqlExpr(sql: a.expr & " != " & b.expr, frag: f)
proc `!=`*(c: ColumnExpr, val: JsonNode): SqlExpr =
  if val.isNil or val.kind == JNull:
    let s = c.expr & " IS NOT NULL"
    SqlExpr(sql: s, frag: litFrag(s))
  else:
    let p = toParam(val)
    SqlExpr(sql: c.expr & " != " & quoteLiteral($val), frag: binFrag(c.expr & " != ", toFrag(p)))

when (NimMajor, NimMinor) >= (2, 2):
  {.pop.}

# String helper operators for ColumnExpr
proc like*(c: ColumnExpr, pattern: string): SqlExpr = makeLikeExpr(c.expr, " LIKE ", pattern)
proc ilike*(c: ColumnExpr, pattern: string): SqlExpr = makeLikeExpr(c.expr, " ILIKE ", pattern)
proc notLike*(c: ColumnExpr, pattern: string): SqlExpr = makeLikeExpr(c.expr, " NOT LIKE ", pattern)
proc notIlike*(c: ColumnExpr, pattern: string): SqlExpr = makeLikeExpr(c.expr, " NOT ILIKE ", pattern)

# NULL helpers for ColumnExpr
proc isNull*(c: ColumnExpr): SqlExpr =
  let s = c.expr & " IS NULL"
  SqlExpr(sql: s, frag: litFrag(s))
proc isNotNull*(c: ColumnExpr): SqlExpr =
  let s = c.expr & " IS NOT NULL"
  SqlExpr(sql: s, frag: litFrag(s))

# IN list helper for ColumnExpr
proc inList*(c: ColumnExpr, items: openArray[string]): SqlExpr = makeInListExpr(c.expr, false, items)
proc inList*(c: ColumnExpr, items: openArray[int]): SqlExpr = makeInListExpr(c.expr, false, items)
proc inList*(c: ColumnExpr, items: openArray[int32]): SqlExpr = makeInListExpr(c.expr, false, items)
proc inList*(c: ColumnExpr, items: openArray[int64]): SqlExpr = makeInListExpr(c.expr, false, items)

proc notInList*(c: ColumnExpr, items: openArray[string]): SqlExpr = makeInListExpr(c.expr, true, items)
proc notInList*(c: ColumnExpr, items: openArray[int]): SqlExpr = makeInListExpr(c.expr, true, items)

# BETWEEN helper for ColumnExpr
proc between*(c: ColumnExpr, minVal, maxVal: int): SqlExpr = makeBetweenExpr(c.expr, minVal, maxVal)
proc between*(c: ColumnExpr, minVal, maxVal: float): SqlExpr = makeBetweenExpr(c.expr, minVal, maxVal)
proc between*(c: ColumnExpr, minVal, maxVal: string): SqlExpr = makeBetweenExpr(c.expr, minVal, maxVal)

# JSON / JSONB operators & helpers
proc `[]`*(c: ColumnRef, key: string): ColumnExpr =
  ## Extracts JSON field as JSON (-> 'key')
  ColumnExpr(expr: $c & " -> " & quoteLiteral(key), alias: "")

proc `[]`*(c: ColumnRef, idx: int): ColumnExpr =
  ## Extracts JSON array element by index as JSON (-> idx)
  ColumnExpr(expr: $c & " -> " & $idx, alias: "")

proc `[]`*(c: ColumnExpr, key: string): ColumnExpr =
  ## Chains extraction of JSON field as JSON (-> 'key')
  ColumnExpr(expr: c.expr & " -> " & quoteLiteral(key), alias: "")

proc `[]`*(c: ColumnExpr, idx: int): ColumnExpr =
  ## Chains extraction of JSON array element by index (-> idx)
  ColumnExpr(expr: c.expr & " -> " & $idx, alias: "")

proc asText*(c: ColumnRef, key: string): ColumnExpr =
  ## Extracts JSON field as text (->> 'key')
  ColumnExpr(expr: $c & " ->> " & quoteLiteral(key), alias: "")

proc asText*(c: ColumnRef, idx: int): ColumnExpr =
  ## Extracts JSON array element as text (->> idx)
  ColumnExpr(expr: $c & " ->> " & $idx, alias: "")

proc asText*(c: ColumnExpr, key: string): ColumnExpr =
  ## Chains extraction of JSON field as text (->> 'key')
  ColumnExpr(expr: c.expr & " ->> " & quoteLiteral(key), alias: "")

proc asText*(c: ColumnExpr, idx: int): ColumnExpr =
  ## Chains extraction of JSON array element as text (->> idx)
  ColumnExpr(expr: c.expr & " ->> " & $idx, alias: "")

proc jsonPath*(c: ColumnRef, pathElements: varargs[string]): ColumnExpr =
  ## Extracts nested JSON object at specified path (#> '{a,b,c}')
  let p = "{" & pathElements.join(",") & "}"
  ColumnExpr(expr: $c & " #> " & quoteLiteral(p), alias: "")

proc jsonPathText*(c: ColumnRef, pathElements: varargs[string]): ColumnExpr =
  ## Extracts nested JSON value as text at specified path (#>> '{a,b,c}')
  let p = "{" & pathElements.join(",") & "}"
  ColumnExpr(expr: $c & " #>> " & quoteLiteral(p), alias: "")

proc containsJson*(c: ColumnRef, jsonVal: JsonNode): SqlExpr =
  ## JSON containment operator (@>)
  makeJsonContainExpr($c, " @> ", jsonVal)

proc containsJson*(c: ColumnRef, jsonVal: string): SqlExpr =
  ## JSON containment operator (@>) with raw string
  makeJsonContainRawExpr($c, " @> ", jsonVal)

proc containsJson*(c: ColumnExpr, jsonVal: JsonNode): SqlExpr =
  ## JSON containment operator (@>) for ColumnExpr
  makeJsonContainExpr(c.expr, " @> ", jsonVal)

proc containsJson*(c: ColumnExpr, jsonVal: string): SqlExpr =
  ## JSON containment operator (@>) with raw string for ColumnExpr
  makeJsonContainRawExpr(c.expr, " @> ", jsonVal)

proc containedByJson*(c: ColumnRef, jsonVal: JsonNode): SqlExpr =
  ## JSON contained-by operator (<@)
  makeJsonContainExpr($c, " <@ ", jsonVal)

proc containedByJson*(c: ColumnRef, jsonVal: string): SqlExpr =
  ## JSON contained-by operator (<@) with raw string
  makeJsonContainRawExpr($c, " <@ ", jsonVal)

proc containedByJson*(c: ColumnExpr, jsonVal: JsonNode): SqlExpr =
  ## JSON contained-by operator (<@) for ColumnExpr
  makeJsonContainExpr(c.expr, " <@ ", jsonVal)

proc containedByJson*(c: ColumnExpr, jsonVal: string): SqlExpr =
  ## JSON contained-by operator (<@) with raw string for ColumnExpr
  makeJsonContainRawExpr(c.expr, " <@ ", jsonVal)

proc hasJsonKey*(c: ColumnRef, key: string): SqlExpr =
  ## Checks if top-level key exists in JSON (?)
  SqlExpr(sql: $c & " ? " & quoteLiteral(key), frag: binFrag($c & " ? ", paramFrag(BoundParam(kind: bpText, textVal: key))))

proc hasJsonKey*(c: ColumnExpr, key: string): SqlExpr =
  ## Checks if top-level key exists in JSON (?) for ColumnExpr
  SqlExpr(sql: c.expr & " ? " & quoteLiteral(key), frag: binFrag(c.expr & " ? ", paramFrag(BoundParam(kind: bpText, textVal: key))))

proc hasAnyJsonKey*(c: ColumnRef, keys: openArray[string]): SqlExpr =
  ## Checks if any top-level key exists in JSON (?|)
  makeJsonKeyArrayExpr($c, " ?| ", keys)

proc hasAnyJsonKey*(c: ColumnExpr, keys: openArray[string]): SqlExpr =
  ## Checks if any top-level key exists in JSON (?|) for ColumnExpr
  makeJsonKeyArrayExpr(c.expr, " ?| ", keys)

proc hasAllJsonKeys*(c: ColumnRef, keys: openArray[string]): SqlExpr =
  ## Checks if all top-level keys exist in JSON (?&)
  makeJsonKeyArrayExpr($c, " ?& ", keys)

proc hasAllJsonKeys*(c: ColumnExpr, keys: openArray[string]): SqlExpr =
  ## Checks if all top-level keys exist in JSON (?&) for ColumnExpr
  makeJsonKeyArrayExpr(c.expr, " ?& ", keys)

# Boolean logic
proc `and`*(a, b: SqlExpr): SqlExpr =
  var f = effectiveFrag(a)
  addLit(f, " AND ")
  addFrag(f, effectiveFrag(b))
  SqlExpr(sql: a.sql & " AND " & b.sql, frag: f)

proc `or`*(a, b: SqlExpr): SqlExpr =
  var f = litFrag("(")
  addFrag(f, effectiveFrag(a))
  addLit(f, " OR ")
  addFrag(f, effectiveFrag(b))
  addLit(f, ")")
  SqlExpr(sql: "(" & a.sql & " OR " & b.sql & ")", frag: f)

proc `not`*(a: SqlExpr): SqlExpr =
  var f = litFrag("NOT (")
  addFrag(f, effectiveFrag(a))
  addLit(f, ")")
  SqlExpr(sql: "NOT (" & a.sql & ")", frag: f)

# Order By modifiers
proc desc*(c: ColumnRef): string = $c & " DESC"
proc asc*(c: ColumnRef): string = $c & " ASC"
proc desc*(e: ColumnExpr): string = e.expr & " DESC"
proc asc*(e: ColumnExpr): string = e.expr & " ASC"
proc desc*(s: string): string = quoteIdent(s) & " DESC"
proc asc*(s: string): string = quoteIdent(s) & " ASC"
proc desc*(id: SqlIdent): string = quoteIdent(string(id)) & " DESC"
proc asc*(id: SqlIdent): string = quoteIdent(string(id)) & " ASC"
proc nullsFirst*(s: string): string = s & " NULLS FIRST"
proc nullsLast*(s: string): string = s & " NULLS LAST"

type
  OrderExpr* = object
    sql*: string

proc `$`*(o: OrderExpr): string = o.sql

converter toOrderExpr*(c: ColumnRef): OrderExpr =
  ## If asc/desc is not specified, direction is omitted: "s"."col"
  OrderExpr(sql: $c)

converter toOrderExpr*(e: ColumnExpr): OrderExpr =
  OrderExpr(sql: e.expr)

converter toOrderExpr*(s: string): OrderExpr =
  OrderExpr(sql: s)

converter toOrderExpr*(id: SqlIdent): OrderExpr =
  OrderExpr(sql: quoteIdent(string(id)))

proc toOrderExpr*[T: distinct](v: T): OrderExpr =
  when isDatumOrContainsDatum[T]():
    {.error: "Raw PostgreSQL Datum cannot be used in ORDER BY; pass a ColumnRef, SqlIdent, or column name string.".}
  else:
    {.error: "Distinct type cannot be implicitly used as an ORDER BY expression; pass a ColumnRef, SqlIdent, or column name string.".}

# SQL Aggregates
proc count*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "COUNT(" & $c & ")", alias: "")
proc count*(s: string): ColumnExpr = ColumnExpr(expr: "COUNT(" & (if s == "*": "*" else: quoteIdent(s, splitQualified = true)) & ")", alias: "")
proc sum*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "SUM(" & $c & ")", alias: "")
proc avg*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "AVG(" & $c & ")", alias: "")
proc minCol*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "MIN(" & $c & ")", alias: "")
proc maxCol*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "MAX(" & $c & ")", alias: "")

# Window Functions
proc rowNumber*(): ColumnExpr = ColumnExpr(expr: "ROW_NUMBER()", alias: "")
proc rank*(): ColumnExpr = ColumnExpr(expr: "RANK()", alias: "")
proc denseRank*(): ColumnExpr = ColumnExpr(expr: "DENSE_RANK()", alias: "")

proc over*(fn: ColumnExpr, partitionBy: openArray[string] = @[], orderBy: openArray[string] = @[]): ColumnExpr =
  var overParts: seq[string] = @[]
  if partitionBy.len > 0:
    overParts.add("PARTITION BY " & partitionBy.join(", "))
  if orderBy.len > 0:
    overParts.add("ORDER BY " & orderBy.join(", "))
  let overStr = if overParts.len > 0: " OVER (" & overParts.join(" ") & ")" else: " OVER ()"
  ColumnExpr(expr: fn.expr & overStr, alias: fn.alias)

proc over*(fn: ColumnExpr, partitionBy: ColumnRef, orderBy: string): ColumnExpr =
  fn.over(partitionBy = @[$partitionBy], orderBy = @[orderBy])

# Conditional CASE WHEN THEN ELSE
proc caseWhen*(condition: SqlExpr): CaseWhenBuilder =
  CaseWhenBuilder(whens: @[(condition.sql, "")], whenFrags: @[(effectiveFrag(condition), SqlFrag())])

proc `then`*(builder: CaseWhenBuilder, value: string): CaseWhenBuilder =
  var b = builder
  let p = toParam(value)
  b.whens[^1][1] = $p
  if b.whenFrags.len > 0:
    b.whenFrags[^1][1] = toFrag(p)
  b

proc `then`*(builder: CaseWhenBuilder, value: int): CaseWhenBuilder =
  var b = builder
  let p = toParam(value)
  b.whens[^1][1] = $p
  if b.whenFrags.len > 0:
    b.whenFrags[^1][1] = toFrag(p)
  b

proc `when`*(builder: CaseWhenBuilder, condition: SqlExpr): CaseWhenBuilder =
  var b = builder
  b.whens.add((condition.sql, ""))
  b.whenFrags.add((effectiveFrag(condition), SqlFrag()))
  b

proc finishCase(builder: CaseWhenBuilder, elseSql: string, elseFrag: SqlFrag): ColumnExpr =
  var parts = @["CASE"]
  var f = litFrag("CASE")
  for i, w in builder.whens:
    parts.add("WHEN " & w[0] & " THEN " & w[1])
    addLit(f, " WHEN ")
    if i < builder.whenFrags.len:
      addFrag(f, builder.whenFrags[i][0])
    else:
      addLit(f, w[0])
    addLit(f, " THEN ")
    if i < builder.whenFrags.len:
      addFrag(f, builder.whenFrags[i][1])
    else:
      addLit(f, w[1])
  parts.add("ELSE " & elseSql)
  parts.add("END")
  addLit(f, " ELSE ")
  addFrag(f, elseFrag)
  addLit(f, " END")
  ColumnExpr(expr: parts.join(" "), alias: "", frag: f)

proc elseEnd*(builder: CaseWhenBuilder, elseVal: string): ColumnExpr =
  let p = toParam(elseVal)
  finishCase(builder, quoteLiteral(elseVal), toFrag(p))

proc elseEnd*(builder: CaseWhenBuilder, elseVal: int): ColumnExpr =
  let p = toParam(elseVal)
  finishCase(builder, $elseVal, toFrag(p))

# =============================================================================
# 4. AST & Step State Machine
# =============================================================================
type
  JoinKind* = enum
    jkInner = "INNER JOIN"
    jkLeft = "LEFT JOIN"
    jkRight = "RIGHT JOIN"
    jkFull = "FULL OUTER JOIN"
    jkCross = "CROSS JOIN"

  JoinClause* = object
    kind*: JoinKind
    isLateral*: bool
    table*: string
    alias*: string
    onCondition*: string
    tableFrag*: SqlFrag
    onFrag*: SqlFrag

  SetOpKind* = enum
    sokNone, sokUnion, sokUnionAll, sokIntersect, sokExcept

  StatementKind* = enum
    skSelect, skValues, skInsert, skUpdate, skDelete

  CteClause* = object
    name*: string
    querySql*: string
    frag*: SqlFrag

  ConflictActionKind* = enum
    cakNone, cakDoNothing, cakDoUpdate

  QueryState* = ref object
    kind*: StatementKind
    isRecursiveCte*: bool
    ctes*: seq[CteClause]
    isDistinct*: bool
    columns*: seq[ColumnExpr]
    table*: string
    alias*: string
    tableFrag*: SqlFrag
    joins*: seq[JoinClause]
    whereExpr*: string
    whereFrag*: SqlFrag
    groupBys*: seq[string]
    havingExpr*: string
    havingFrag*: SqlFrag
    orderBys*: seq[string]
    limitVal*: int
    offsetVal*: int
    # Set Operations (UNION, INTERSECT, etc)
    setOpKind*: SetOpKind
    setOpTarget*: string
    setOpTargetFrag*: SqlFrag
    # VALUES
    valuesRows*: seq[seq[string]]
    valuesRowsFrag*: seq[seq[SqlFrag]]
    # INSERT / UPDATE / DELETE
    insertCols*: seq[string]
    insertRows*: seq[seq[string]]
    insertRowsFrag*: seq[seq[SqlFrag]]
    updateSets*: seq[string]
    updateSetsFrag*: seq[SqlFrag]
    returningCols*: seq[ColumnExpr]
    # PostgreSQL ON CONFLICT (UPSERT)
    conflictCols*: seq[string]
    conflictAction*: ConflictActionKind
    conflictUpdates*: seq[string]
    conflictUpdatesFrag*: seq[SqlFrag]

  WithStep* = object
    state*: QueryState

  SelectStep* = object
    state*: QueryState

  FromStep* = object
    state*: QueryState

  JoinStep* = object
    state*: QueryState
    currentJoin*: JoinClause

  WhereStep* = object
    state*: QueryState

  GroupByStep* = object
    state*: QueryState

  HavingStep* = object
    state*: QueryState

  OrderByStep* = object
    state*: QueryState

  LimitStep* = object
    state*: QueryState

  OffsetStep* = object
    state*: QueryState

  ValuesStep* = object
    state*: QueryState

  InsertStep* = object
    state*: QueryState

  InsertValuesStep* = object
    state*: QueryState

  ConflictStep* = object
    state*: QueryState

  UpdateStep* = object
    state*: QueryState

  UpdateSetStep* = object
    state*: QueryState

  UpdateWhereStep* = object
    state*: QueryState

  DeleteStep* = object
    state*: QueryState

  DeleteWhereStep* = object
    state*: QueryState

  ExecutableQuery* = SelectStep or FromStep or WhereStep or GroupByStep or 
                     HavingStep or OrderByStep or LimitStep or OffsetStep or 
                     ValuesStep or InsertValuesStep or ConflictStep or 
                     UpdateSetStep or UpdateWhereStep or DeleteStep or DeleteWhereStep

# Forward declaration for stringifier & binary parameterization
proc toSql*(st: QueryState): string
proc toFrag*(st: QueryState): SqlFrag
proc `$`*(step: ExecutableQuery): string = toSql(step.state)
proc toParameterizedSql*(q: ExecutableQuery): ParameterizedQuery =
  ## Compiles an ExecutableQuery into a parameterized SQL statement (`$1, $2, ...`) and binary `BoundParam` list.
  renderParameterized(toFrag(q.state))

# Subquery helpers (type-safe ARRAY(SELECT ...), EXISTS, IN)
proc wrapSubqueryFrag(prefix: string, st: QueryState, suffix: string): SqlFrag =
  result = litFrag(prefix)
  addFrag(result, toFrag(st))
  addLit(result, suffix)

proc asArray*(step: ExecutableQuery): SqlExpr =
  SqlExpr(sql: "ARRAY(" & $step & ")", frag: wrapSubqueryFrag("ARRAY(", step.state, ")"))
proc exists*(step: ExecutableQuery): SqlExpr =
  SqlExpr(sql: "EXISTS (" & $step & ")", frag: wrapSubqueryFrag("EXISTS (", step.state, ")"))
proc inSubquery*(c: ColumnRef, step: ExecutableQuery): SqlExpr =
  SqlExpr(sql: $c & " IN (" & $step & ")", frag: wrapSubqueryFrag($c & " IN (", step.state, ")"))
proc notInSubquery*(c: ColumnRef, step: ExecutableQuery): SqlExpr =
  SqlExpr(sql: $c & " NOT IN (" & $step & ")", frag: wrapSubqueryFrag($c & " NOT IN (", step.state, ")"))

# Column conversion helpers
proc colExpr*(expr: string, alias: string = ""): ColumnExpr = ColumnExpr(expr: expr, alias: alias)
proc withAlias*(c: ColumnExpr, alias: string): ColumnExpr {.inline.} =
  ColumnExpr(expr: c.expr, alias: alias, frag: c.frag)
proc toColumnExpr*(e: SqlExpr): ColumnExpr = ColumnExpr(expr: e.sql, alias: "", frag: effectiveFrag(e))
proc toColumnExpr*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: $c, alias: "")
proc toColumnExpr*(id: SqlIdent): ColumnExpr = ColumnExpr(expr: $id, alias: "")
proc toColumnExpr*(r: RawSql): ColumnExpr = ColumnExpr(expr: $r, alias: "")
proc toColumnExpr*(s: string): ColumnExpr = ColumnExpr(expr: quoteIdent(s, splitQualified = true), alias: "")
proc toColumnExpr*(n: int): ColumnExpr =
  let p = toParam(n)
  ColumnExpr(expr: $n, alias: "", frag: toFrag(p))
proc toColumnExpr*(n: int32): ColumnExpr =
  let p = toParam(n)
  ColumnExpr(expr: $n, alias: "", frag: toFrag(p))
proc toColumnExpr*(n: int64): ColumnExpr =
  let p = toParam(n)
  ColumnExpr(expr: $n, alias: "", frag: toFrag(p))
proc toColumnExpr*(f: float): ColumnExpr =
  let p = toParam(f)
  ColumnExpr(expr: formatPgFloat(f), alias: "", frag: toFrag(p))
proc toColumnExpr*(b: bool): ColumnExpr =
  let p = toParam(b)
  ColumnExpr(expr: (if b: "TRUE" else: "FALSE"), alias: "", frag: toFrag(p))
proc toColumnExpr*(j: JsonNode): ColumnExpr =
  if j.isNil or j.kind == JNull:
    ColumnExpr(expr: "NULL::jsonb", alias: "")
  else:
    let p = toParam(j)
    ColumnExpr(expr: quoteLiteral($j) & "::jsonb", alias: "", frag: toFrag(p))
proc toColumnExpr*(p: QueryParam): ColumnExpr =
  ColumnExpr(expr: $p, alias: "", frag: toFrag(p))
proc toColumnExpr*(c: ColumnExpr): ColumnExpr = c
proc toColumnExpr*(q: ExecutableQuery): ColumnExpr =
  ColumnExpr(expr: "(" & $q & ")", alias: "", frag: wrapSubqueryFrag("(", q.state, ")"))

template `as`*(a: typed, b: string): ColumnExpr =
  when isDatumOrContainsDatum[typeof(a)]():
    {.error: "Raw PostgreSQL Datum cannot be selected or aliased in QueryBuilder; convert it to a typed Nim value first.".}
  else:
    (when compiles(toColumnExpr(a)): withAlias(toColumnExpr(a), b) else: colExpr(quoteIdent($a), b))

# =============================================================================
# 5. Macros for Infix `as`
# =============================================================================
proc SelectImpl*(cols: varargs[ColumnExpr]): SelectStep =
  SelectStep(state: QueryState(kind: skSelect, columns: cols.toSeq, limitVal: -1, offsetVal: -1))

proc SelectDistinctImpl*(cols: varargs[ColumnExpr]): SelectStep =
  SelectStep(state: QueryState(kind: skSelect, isDistinct: true, columns: cols.toSeq, limitVal: -1, offsetVal: -1))

proc SelectWithImpl*(step: WithStep, cols: varargs[ColumnExpr]): SelectStep =
  step.state.columns = cols.toSeq
  SelectStep(state: step.state)

proc parseColNode(node: NimNode): NimNode =
  if node.kind == nnkInfix and node[0].eqIdent("as"):
    let col = node[1]
    let al = node[2]
    result = quote do:
      when isDatumOrContainsDatum[typeof(`col`)]():
        {.error: "Raw PostgreSQL Datum cannot be selected or aliased in QueryBuilder; convert it to a typed Nim value first.".}
      else:
        (when compiles(toColumnExpr(`col`)): withAlias(toColumnExpr(`col`), $`al`) else: colExpr(quoteIdent($`col`), $`al`))
  else:
    result = quote do:
      toColumnExpr(`node`)

macro Select*(args: varargs[untyped]): untyped =
  result = newCall(bindSym"SelectImpl")
  for arg in args:
    result.add parseColNode(arg)

macro SelectDistinct*(args: varargs[untyped]): untyped =
  result = newCall(bindSym"SelectDistinctImpl")
  for arg in args:
    result.add parseColNode(arg)

macro Select*(step: WithStep, args: varargs[untyped]): untyped =
  result = newCall(bindSym"SelectWithImpl", step)
  for arg in args:
    result.add parseColNode(arg)

# =============================================================================
# 6. CTEs (Common Table Expressions: WITH / WITH RECURSIVE)
# =============================================================================
proc WithCte*(name: string, subquery: ExecutableQuery, recursive: bool = false): WithStep =
  let st = QueryState(
    kind: skSelect, 
    isRecursiveCte: recursive,
    ctes: @[CteClause(name: quoteIdent(name), querySql: $subquery, frag: toFrag(subquery.state))],
    limitVal: -1, 
    offsetVal: -1
  )
  WithStep(state: st)

proc AndWith*(step: WithStep, name: string, subquery: ExecutableQuery): WithStep =
  step.state.ctes.add(CteClause(name: quoteIdent(name), querySql: $subquery, frag: toFrag(subquery.state)))
  step

# =============================================================================
# 7. Step Builder Methods (FROM, JOINS, WHERE, GROUP BY, ORDER BY, LIMIT, OFFSET)
# =============================================================================
proc From*(step: SelectStep, t: TableRef): FromStep =
  step.state.table = quoteIdent(t.rawTable)
  step.state.alias = if t.rawAlias.len > 0: quoteIdent(t.rawAlias) else: ""
  step.state.tableFrag = SqlFrag()
  FromStep(state: step.state)

proc From*(step: SelectStep, table: string, alias: string = ""): FromStep =
  step.From(TableRef(rawTable: table, rawAlias: alias))

proc From*(step: SelectStep, subquery: ExecutableQuery, alias: string): FromStep =
  step.state.table = "(" & $subquery & ")"
  step.state.alias = quoteIdent(alias)
  step.state.tableFrag = wrapSubqueryFrag("(", subquery.state, ")")
  FromStep(state: step.state)

# Joins with TableRef or Subquery
proc Join*(step: FromStep, kind: JoinKind, t: TableRef, isLateral: bool = false): JoinStep =
  JoinStep(state: step.state, currentJoin: JoinClause(
    kind: kind, 
    isLateral: isLateral, 
    table: quoteIdent(t.rawTable), 
    alias: if t.rawAlias.len > 0: quoteIdent(t.rawAlias) else: ""
  ))

proc Join*(step: FromStep, kind: JoinKind, subquery: ExecutableQuery, alias: string, isLateral: bool = false): JoinStep =
  JoinStep(state: step.state, currentJoin: JoinClause(
    kind: kind, 
    isLateral: isLateral, 
    table: "(" & $subquery & ")", 
    alias: quoteIdent(alias),
    tableFrag: wrapSubqueryFrag("(", subquery.state, ")")
  ))

proc InnerJoin*(step: FromStep, t: TableRef): JoinStep = step.Join(jkInner, t)
proc LeftJoin*(step: FromStep, t: TableRef): JoinStep = step.Join(jkLeft, t)
proc RightJoin*(step: FromStep, t: TableRef): JoinStep = step.Join(jkRight, t)
proc FullJoin*(step: FromStep, t: TableRef): JoinStep = step.Join(jkFull, t)

proc InnerJoin*(step: FromStep, table: string, alias: string = ""): JoinStep = step.Join(jkInner, TableRef(rawTable: table, rawAlias: alias))
proc LeftJoin*(step: FromStep, table: string, alias: string = ""): JoinStep = step.Join(jkLeft, TableRef(rawTable: table, rawAlias: alias))
proc RightJoin*(step: FromStep, table: string, alias: string = ""): JoinStep = step.Join(jkRight, TableRef(rawTable: table, rawAlias: alias))
proc FullJoin*(step: FromStep, table: string, alias: string = ""): JoinStep = step.Join(jkFull, TableRef(rawTable: table, rawAlias: alias))

proc LeftJoinLateral*(step: FromStep, subquery: ExecutableQuery, alias: string): JoinStep = step.Join(jkLeft, subquery, alias, isLateral = true)
proc InnerJoinLateral*(step: FromStep, subquery: ExecutableQuery, alias: string): JoinStep = step.Join(jkInner, subquery, alias, isLateral = true)

proc CrossJoinLateral*(step: FromStep, subquery: ExecutableQuery, alias: string): FromStep =
  step.state.joins.add(JoinClause(
    kind: jkCross,
    isLateral: true,
    table: "(" & $subquery & ")",
    alias: quoteIdent(alias),
    tableFrag: wrapSubqueryFrag("(", subquery.state, ")")
  ))
  step

# ON
proc On*(step: JoinStep, expr: SqlExpr): FromStep =
  var j = step.currentJoin
  j.onCondition = expr.sql
  j.onFrag = effectiveFrag(expr)
  step.state.joins.add(j)
  FromStep(state: step.state)

proc On*(step: JoinStep, condition: string): FromStep =
  step.On(SqlExpr(sql: condition))

# WHERE
proc Where*(step: FromStep, expr: SqlExpr): WhereStep =
  step.state.whereExpr = expr.sql
  step.state.whereFrag = effectiveFrag(expr)
  WhereStep(state: step.state)

proc And*(step: WhereStep, expr: SqlExpr): WhereStep =
  if isEmptyFrag(step.state.whereFrag) and step.state.whereExpr.len > 0:
    step.state.whereFrag = litFrag(step.state.whereExpr)
  step.state.whereExpr.add(" AND " & expr.sql)
  addLit(step.state.whereFrag, " AND ")
  addFrag(step.state.whereFrag, effectiveFrag(expr))
  step

proc Or*(step: WhereStep, expr: SqlExpr): WhereStep =
  let curFrag = if not isEmptyFrag(step.state.whereFrag): step.state.whereFrag else: litFrag(step.state.whereExpr)
  var newFrag = litFrag("(")
  addFrag(newFrag, curFrag)
  addLit(newFrag, " OR ")
  addFrag(newFrag, effectiveFrag(expr))
  addLit(newFrag, ")")
  step.state.whereExpr = "(" & step.state.whereExpr & " OR " & expr.sql & ")"
  step.state.whereFrag = newFrag
  step

# GROUP BY & HAVING
proc GroupBy*(step: FromStep or WhereStep, cols: varargs[string]): GroupByStep =
  step.state.groupBys.add(cols.mapIt(quoteIdent(it)))
  GroupByStep(state: step.state)

proc GroupBy*(step: FromStep or WhereStep, cols: varargs[ColumnRef]): GroupByStep =
  step.state.groupBys.add(cols.mapIt($it))
  GroupByStep(state: step.state)

proc GroupBy*(step: FromStep or WhereStep, cols: varargs[ColumnExpr]): GroupByStep =
  step.state.groupBys.add(cols.mapIt(it.expr))
  GroupByStep(state: step.state)

proc GroupBy*(step: FromStep or WhereStep, cols: varargs[SqlIdent]): GroupByStep =
  step.state.groupBys.add(cols.mapIt(quoteIdent(string(it))))
  GroupByStep(state: step.state)

proc Having*(step: GroupByStep, expr: SqlExpr): HavingStep =
  step.state.havingExpr = expr.sql
  step.state.havingFrag = effectiveFrag(expr)
  HavingStep(state: step.state)

# ORDER BY
proc OrderBy*(step: FromStep or WhereStep or GroupByStep or HavingStep, cols: varargs[OrderExpr, toOrderExpr]): OrderByStep =
  for c in cols:
    step.state.orderBys.add(c.sql)
  OrderByStep(state: step.state)

# LIMIT & OFFSET
proc Limit*(step: SelectStep or FromStep or WhereStep or GroupByStep or HavingStep or OrderByStep or ValuesStep, n: int): LimitStep =
  step.state.limitVal = n
  LimitStep(state: step.state)

proc Offset*(step: SelectStep or FromStep or WhereStep or GroupByStep or HavingStep or OrderByStep or LimitStep or ValuesStep, n: int): OffsetStep =
  step.state.offsetVal = n
  OffsetStep(state: step.state)

# Fluent pagination aliases
template Take*(step: untyped, n: int): untyped = step.Limit(n)
template Skip*(step: untyped, n: int): untyped = step.Offset(n)

# =============================================================================
# 8. Set Operations (UNION, UNION ALL, INTERSECT, EXCEPT)
# =============================================================================
proc Union*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokUnion
  st.setOpTarget = $q2
  st.setOpTargetFrag = toFrag(q2.state)
  SelectStep(state: st)

proc UnionAll*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokUnionAll
  st.setOpTarget = $q2
  st.setOpTargetFrag = toFrag(q2.state)
  SelectStep(state: st)

proc Intersect*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokIntersect
  st.setOpTarget = $q2
  st.setOpTargetFrag = toFrag(q2.state)
  SelectStep(state: st)

proc Except*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokExcept
  st.setOpTarget = $q2
  st.setOpTargetFrag = toFrag(q2.state)
  SelectStep(state: st)

# =============================================================================
# 9. PostgreSQL Standalone VALUES & Rows
# =============================================================================
type
  SqlRow* = object
    cells*: seq[string]
    frags*: seq[SqlFrag]

proc RowImpl*(params: openArray[QueryParam]): SqlRow =
  var res = newSeq[string](params.len)
  var frags = newSeq[SqlFrag](params.len)
  for i, p in params:
    res[i] = $p
    frags[i] = toFrag(p)
  SqlRow(cells: res, frags: frags)

macro Row*(args: varargs[untyped]): untyped =
  var arr = newNimNode(nnkBracket)
  for a in args:
    arr.add(newCall(bindSym"toQueryParamEx", a))
  result = newCall(bindSym"RowImpl", nnkPrefix.newTree(newIdentNode("@"), arr))

proc Values*(rows: varargs[SqlRow]): ValuesStep =
  var rawRows: seq[seq[string]] = @[]
  var fragRows: seq[seq[SqlFrag]] = @[]
  for r in rows:
    rawRows.add(r.cells)
    fragRows.add(r.frags)
  let st = QueryState(kind: skValues, valuesRows: rawRows, valuesRowsFrag: fragRows, limitVal: -1, offsetVal: -1)
  ValuesStep(state: st)

# =============================================================================
# 10. INSERT, PostgreSQL UPSERT (ON CONFLICT), UPDATE, DELETE Steps
# =============================================================================
proc InsertInto*(table: string, cols: varargs[string]): InsertStep =
  InsertStep(state: QueryState(kind: skInsert, table: quoteIdent(table), insertCols: cols.mapIt(quoteIdent(it))))

proc InsertInto*(t: TableRef, cols: varargs[string]): InsertStep =
  InsertInto(t.rawTable, cols)

proc InsertInto*(t: TableRef, cols: varargs[ColumnRef]): InsertStep =
  InsertStep(state: QueryState(kind: skInsert, table: quoteIdent(t.rawTable), insertCols: cols.mapIt(quoteIdent(it.rawCol))))

proc InsertInto*(table: string, cols: varargs[ColumnRef]): InsertStep =
  InsertStep(state: QueryState(kind: skInsert, table: quoteIdent(table), insertCols: cols.mapIt(quoteIdent(it.rawCol))))

proc ValuesParamsImpl*(step: InsertStep or InsertValuesStep, params: openArray[QueryParam]): InsertValuesStep =
  var formattedRow = newSeq[string](params.len)
  var fragRow = newSeq[SqlFrag](params.len)
  for i, p in params:
    formattedRow[i] = $p
    fragRow[i] = toFrag(p)
  step.state.insertRows.add(formattedRow)
  step.state.insertRowsFrag.add(fragRow)
  InsertValuesStep(state: step.state)

proc ValuesRowImpl*(step: InsertStep or InsertValuesStep, row: SqlRow): InsertValuesStep =
  step.state.insertRows.add(row.cells)
  step.state.insertRowsFrag.add(row.frags)
  InsertValuesStep(state: step.state)

macro Values*(step: InsertStep or InsertValuesStep, args: varargs[untyped]): untyped =
  if args.len == 0:
    return newCall(bindSym"ValuesParamsImpl", step, nnkPrefix.newTree(newIdentNode("@"), newNimNode(nnkBracket)))
  if args.len == 1:
    let arg0 = args[0]
    return quote do:
      when typeof(`arg0`) is SqlRow:
        ValuesRowImpl(`step`, `arg0`)
      else:
        ValuesParamsImpl(`step`, @[toQueryParamEx(`arg0`)])
  var arr = newNimNode(nnkBracket)
  for a in args:
    arr.add(newCall(bindSym"toQueryParamEx", a))
  result = newCall(bindSym"ValuesParamsImpl", step, nnkPrefix.newTree(newIdentNode("@"), arr))

proc OnConflict*(step: InsertValuesStep, cols: varargs[string]): ConflictStep =
  step.state.conflictCols = cols.mapIt(quoteIdent(it))
  ConflictStep(state: step.state)

proc OnConflict*(step: InsertValuesStep, cols: varargs[ColumnRef]): ConflictStep =
  step.state.conflictCols = cols.mapIt(quoteIdent(it.rawCol))
  ConflictStep(state: step.state)

proc DoNothing*(step: ConflictStep): InsertValuesStep =
  step.state.conflictAction = cakDoNothing
  InsertValuesStep(state: step.state)

proc cleanSetExpr*(sql: string): string =
  ## Strips table qualifier in SET clauses (e.g. "u"."name" = val -> "name" = val, or u.name = val -> name = val)
  if sql.len > 0 and sql[0] == '"':
    let dotPos = sql.find("\".\"")
    let eqPos = sql.find('=')
    if dotPos != -1 and eqPos != -1 and dotPos < eqPos:
      return sql[dotPos + 2 .. ^1]
  elif sql.len > 0:
    let dotPos = sql.find('.')
    let eqPos = sql.find('=')
    if dotPos != -1 and eqPos != -1 and dotPos < eqPos:
      return sql[dotPos + 1 .. ^1]
  return sql

proc cleanSetFrag(e: SqlExpr): SqlFrag =
  result = effectiveFrag(e)
  if result.chunks.len > 0 and result.chunks[0].paramIdx < 0:
    result.chunks[0].text = cleanSetExpr(result.chunks[0].text)

proc DoUpdate*(step: ConflictStep, exprs: varargs[SqlExpr]): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  for e in exprs:
    step.state.conflictUpdates.add(cleanSetExpr(e.sql))
    step.state.conflictUpdatesFrag.add(cleanSetFrag(e))
  InsertValuesStep(state: step.state)

proc DoUpdate*(step: ConflictStep, col: ColumnRef, val: QueryParam): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  let prefix = quoteIdent(col.rawCol) & " = "
  step.state.conflictUpdates.add(prefix & $val)
  step.state.conflictUpdatesFrag.add(binFrag(prefix, toFrag(val)))
  InsertValuesStep(state: step.state)

proc DoUpdate*[T: not QueryParam](step: ConflictStep, col: ColumnRef, val: T): InsertValuesStep =
  DoUpdate(step, col, toQueryParamEx(val))

proc DoUpdate*(step: ConflictStep, sets: varargs[string]): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  for s in sets:
    let cleaned = cleanSetExpr(s)
    step.state.conflictUpdates.add(cleaned)
    step.state.conflictUpdatesFrag.add(litFrag(cleaned))
  InsertValuesStep(state: step.state)

proc Returning*(step: InsertValuesStep or ConflictStep, cols: varargs[string]): InsertValuesStep =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: quoteIdent(it), alias: ""))
  InsertValuesStep(state: step.state)

proc Returning*(step: InsertValuesStep or ConflictStep, cols: varargs[ColumnRef]): InsertValuesStep =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: $it, alias: ""))
  InsertValuesStep(state: step.state)

proc Returning*(step: InsertValuesStep or ConflictStep, cols: varargs[ColumnExpr]): InsertValuesStep =
  step.state.returningCols = cols.toSeq
  InsertValuesStep(state: step.state)

# UPDATE
proc Update*(table: string): UpdateStep =
  UpdateStep(state: QueryState(kind: skUpdate, table: quoteIdent(table)))

proc Update*(t: TableRef): UpdateStep =
  Update(t.rawTable)

proc Set*(step: UpdateStep or UpdateSetStep, exprs: varargs[SqlExpr]): UpdateSetStep =
  for e in exprs:
    step.state.updateSets.add(cleanSetExpr(e.sql))
    step.state.updateSetsFrag.add(cleanSetFrag(e))
  UpdateSetStep(state: step.state)

proc Set*(step: UpdateStep or UpdateSetStep, col: ColumnRef, val: QueryParam): UpdateSetStep =
  let prefix = quoteIdent(col.rawCol) & " = "
  step.state.updateSets.add(prefix & $val)
  step.state.updateSetsFrag.add(binFrag(prefix, toFrag(val)))
  UpdateSetStep(state: step.state)

proc Set*[T: not QueryParam](step: UpdateStep or UpdateSetStep, col: ColumnRef, val: T): UpdateSetStep =
  Set(step, col, toQueryParamEx(val))

proc Set*(step: UpdateStep or UpdateSetStep, sets: varargs[string]): UpdateSetStep =
  for s in sets:
    let cleaned = cleanSetExpr(s)
    step.state.updateSets.add(cleaned)
    step.state.updateSetsFrag.add(litFrag(cleaned))
  UpdateSetStep(state: step.state)

proc Where*(step: UpdateSetStep, expr: SqlExpr): UpdateWhereStep =
  step.state.whereExpr = expr.sql
  step.state.whereFrag = effectiveFrag(expr)
  UpdateWhereStep(state: step.state)

proc Returning*(step: UpdateSetStep or UpdateWhereStep, cols: varargs[string]): ExecutableQuery =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: quoteIdent(it), alias: ""))
  step

proc Returning*(step: UpdateSetStep or UpdateWhereStep, cols: varargs[ColumnRef]): ExecutableQuery =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: $it, alias: ""))
  step

proc Returning*(step: UpdateSetStep or UpdateWhereStep, cols: varargs[ColumnExpr]): ExecutableQuery =
  step.state.returningCols = cols.toSeq
  step

# DELETE
proc DeleteFrom*(table: string): DeleteStep =
  DeleteStep(state: QueryState(kind: skDelete, table: quoteIdent(table)))

proc DeleteFrom*(t: TableRef): DeleteStep =
  DeleteFrom(t.rawTable)

proc Where*(step: DeleteStep, expr: SqlExpr): DeleteWhereStep =
  step.state.whereExpr = expr.sql
  step.state.whereFrag = effectiveFrag(expr)
  DeleteWhereStep(state: step.state)

proc Returning*(step: DeleteStep or DeleteWhereStep, cols: varargs[string]): ExecutableQuery =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: quoteIdent(it), alias: ""))
  step

proc Returning*(step: DeleteStep or DeleteWhereStep, cols: varargs[ColumnRef]): ExecutableQuery =
  step.state.returningCols = cols.mapIt(ColumnExpr(expr: $it, alias: ""))
  step

proc Returning*(step: DeleteStep or DeleteWhereStep, cols: varargs[ColumnExpr]): ExecutableQuery =
  step.state.returningCols = cols.toSeq
  step

# =============================================================================
# 11. SQL Generator (Text & Binary Parameterized)
# =============================================================================
proc toSql*(st: QueryState): string =
  var res = ""
  
  # CTE Header (WITH / WITH RECURSIVE)
  if st.ctes.len > 0:
    let recStr = if st.isRecursiveCte: "RECURSIVE " else: ""
    var cteStrs: seq[string] = @[]
    for c in st.ctes:
      cteStrs.add(c.name & " AS (\n" & c.querySql & "\n)")
    res.add("WITH " & recStr & cteStrs.join(",\n") & "\n")

  case st.kind:
  of skSelect:
    var parts: seq[string] = @[]
    let distinctStr = if st.isDistinct: "DISTINCT " else: ""
    let cols = st.columns.mapIt(if it.alias.len > 0: it.expr & " AS " & quoteIdent(it.alias) else: it.expr)
    parts.add("SELECT " & distinctStr & cols.join(", "))
    
    if st.table.len > 0:
      var fromStr = "FROM " & st.table
      if st.alias.len > 0: fromStr.add(" " & st.alias)
      parts.add(fromStr)
      
    for j in st.joins:
      var jStr = $j.kind
      if j.isLateral: jStr.add(" LATERAL")
      jStr.add(" " & j.table)
      if j.alias.len > 0: jStr.add(" " & j.alias)
      if j.kind != jkCross: jStr.add(" ON " & j.onCondition)
      parts.add(jStr)
      
    if st.whereExpr.len > 0: parts.add("WHERE " & st.whereExpr)
    if st.groupBys.len > 0: parts.add("GROUP BY " & st.groupBys.join(", "))
    if st.havingExpr.len > 0: parts.add("HAVING " & st.havingExpr)
    if st.orderBys.len > 0: parts.add("ORDER BY " & st.orderBys.join(", "))
    if st.limitVal >= 0: parts.add("LIMIT " & $st.limitVal)
    if st.offsetVal >= 0: parts.add("OFFSET " & $st.offsetVal)
    
    res.add(parts.join("\n"))

    # Set Operations (UNION, INTERSECT, EXCEPT)
    case st.setOpKind:
    of sokUnion: res.add("\nUNION\n" & st.setOpTarget)
    of sokUnionAll: res.add("\nUNION ALL\n" & st.setOpTarget)
    of sokIntersect: res.add("\nINTERSECT\n" & st.setOpTarget)
    of sokExcept: res.add("\nEXCEPT\n" & st.setOpTarget)
    of sokNone: discard

    return res

  of skValues:
    res.add("VALUES\n  ")
    var rowStrs: seq[string] = @[]
    for row in st.valuesRows:
      rowStrs.add("(" & row.join(", ") & ")")
    res.add(rowStrs.join(",\n  "))
    if st.limitVal >= 0: res.add("\nLIMIT " & $st.limitVal)
    if st.offsetVal >= 0: res.add("\nOFFSET " & $st.offsetVal)
    return res
    
  of skInsert:
    res.add("INSERT INTO " & st.table)
    if st.insertCols.len > 0: res.add(" (" & st.insertCols.join(", ") & ")")
    res.add("\nVALUES\n  ")
    var rowStrs: seq[string] = @[]
    for row in st.insertRows:
      rowStrs.add("(" & row.join(", ") & ")")
    res.add(rowStrs.join(",\n  "))

    # PostgreSQL ON CONFLICT (UPSERT)
    if st.conflictAction != cakNone:
      var confStr = "\nON CONFLICT"
      if st.conflictCols.len > 0:
        confStr.add(" (" & st.conflictCols.join(", ") & ")")
      if st.conflictAction == cakDoNothing:
        confStr.add(" DO NOTHING")
      elif st.conflictAction == cakDoUpdate:
        confStr.add(" DO UPDATE SET " & st.conflictUpdates.join(", "))
      res.add(confStr)

    if st.returningCols.len > 0:
      let ret = st.returningCols.mapIt(if it.alias.len > 0: it.expr & " AS " & quoteIdent(it.alias) else: it.expr)
      res.add("\nRETURNING " & ret.join(", "))
    return res
    
  of skUpdate:
    res.add("UPDATE " & st.table & "\nSET " & st.updateSets.join(", "))
    if st.whereExpr.len > 0: res.add("\nWHERE " & st.whereExpr)
    if st.returningCols.len > 0:
      let ret = st.returningCols.mapIt(if it.alias.len > 0: it.expr & " AS " & quoteIdent(it.alias) else: it.expr)
      res.add("\nRETURNING " & ret.join(", "))
    return res

  of skDelete:
    res.add("DELETE FROM " & st.table)
    if st.whereExpr.len > 0: res.add("\nWHERE " & st.whereExpr)
    if st.returningCols.len > 0:
      let ret = st.returningCols.mapIt(if it.alias.len > 0: it.expr & " AS " & quoteIdent(it.alias) else: it.expr)
      res.add("\nRETURNING " & ret.join(", "))
    return res

proc appendColumnExprsFrag(dst: var SqlFrag, cols: seq[ColumnExpr]) =
  for i, c in cols:
    if i > 0:
      addLit(dst, ", ")
    addFrag(dst, effectiveFrag(c))
    if c.alias.len > 0:
      addLit(dst, " AS " & quoteIdent(c.alias))

proc appendRowsFrag(dst: var SqlFrag, rows: seq[seq[string]], rowsFrag: seq[seq[SqlFrag]]) =
  for rIdx, row in rows:
    if rIdx > 0:
      addLit(dst, ",\n  ")
    addLit(dst, "(")
    for cIdx, cell in row:
      if cIdx > 0:
        addLit(dst, ", ")
      if rIdx < rowsFrag.len and cIdx < rowsFrag[rIdx].len and not isEmptyFrag(rowsFrag[rIdx][cIdx]):
        addFrag(dst, rowsFrag[rIdx][cIdx])
      else:
        addLit(dst, cell)
    addLit(dst, ")")

proc toFrag*(st: QueryState): SqlFrag =
  if st.ctes.len > 0:
    let recStr = if st.isRecursiveCte: "RECURSIVE " else: ""
    addLit(result, "WITH " & recStr)
    for i, c in st.ctes:
      if i > 0:
        addLit(result, ",\n")
      addLit(result, c.name & " AS (\n")
      if not isEmptyFrag(c.frag):
        addFrag(result, c.frag)
      else:
        addLit(result, c.querySql)
      addLit(result, "\n)")
    addLit(result, "\n")

  case st.kind:
  of skSelect:
    let distinctStr = if st.isDistinct: "DISTINCT " else: ""
    addLit(result, "SELECT " & distinctStr)
    appendColumnExprsFrag(result, st.columns)

    if st.table.len > 0:
      addLit(result, "\nFROM ")
      if not isEmptyFrag(st.tableFrag):
        addFrag(result, st.tableFrag)
      else:
        addLit(result, st.table)
      if st.alias.len > 0:
        addLit(result, " " & st.alias)

    for j in st.joins:
      addLit(result, "\n" & $j.kind)
      if j.isLateral:
        addLit(result, " LATERAL")
      addLit(result, " ")
      if not isEmptyFrag(j.tableFrag):
        addFrag(result, j.tableFrag)
      else:
        addLit(result, j.table)
      if j.alias.len > 0:
        addLit(result, " " & j.alias)
      if j.kind != jkCross:
        addLit(result, " ON ")
        if not isEmptyFrag(j.onFrag):
          addFrag(result, j.onFrag)
        else:
          addLit(result, j.onCondition)

    if st.whereExpr.len > 0:
      addLit(result, "\nWHERE ")
      if not isEmptyFrag(st.whereFrag):
        addFrag(result, st.whereFrag)
      else:
        addLit(result, st.whereExpr)

    if st.groupBys.len > 0:
      addLit(result, "\nGROUP BY " & st.groupBys.join(", "))

    if st.havingExpr.len > 0:
      addLit(result, "\nHAVING ")
      if not isEmptyFrag(st.havingFrag):
        addFrag(result, st.havingFrag)
      else:
        addLit(result, st.havingExpr)

    if st.orderBys.len > 0:
      addLit(result, "\nORDER BY " & st.orderBys.join(", "))
    if st.limitVal >= 0:
      addLit(result, "\nLIMIT " & $st.limitVal)
    if st.offsetVal >= 0:
      addLit(result, "\nOFFSET " & $st.offsetVal)

    if st.setOpKind != sokNone:
      case st.setOpKind:
      of sokUnion: addLit(result, "\nUNION\n")
      of sokUnionAll: addLit(result, "\nUNION ALL\n")
      of sokIntersect: addLit(result, "\nINTERSECT\n")
      of sokExcept: addLit(result, "\nEXCEPT\n")
      of sokNone: discard
      if not isEmptyFrag(st.setOpTargetFrag):
        addFrag(result, st.setOpTargetFrag)
      else:
        addLit(result, st.setOpTarget)

  of skValues:
    addLit(result, "VALUES\n  ")
    appendRowsFrag(result, st.valuesRows, st.valuesRowsFrag)
    if st.limitVal >= 0:
      addLit(result, "\nLIMIT " & $st.limitVal)
    if st.offsetVal >= 0:
      addLit(result, "\nOFFSET " & $st.offsetVal)

  of skInsert:
    addLit(result, "INSERT INTO " & st.table)
    if st.insertCols.len > 0:
      addLit(result, " (" & st.insertCols.join(", ") & ")")
    addLit(result, "\nVALUES\n  ")
    appendRowsFrag(result, st.insertRows, st.insertRowsFrag)

    if st.conflictAction != cakNone:
      addLit(result, "\nON CONFLICT")
      if st.conflictCols.len > 0:
        addLit(result, " (" & st.conflictCols.join(", ") & ")")
      if st.conflictAction == cakDoNothing:
        addLit(result, " DO NOTHING")
      elif st.conflictAction == cakDoUpdate:
        addLit(result, " DO UPDATE SET ")
        for i, s in st.conflictUpdates:
          if i > 0:
            addLit(result, ", ")
          if i < st.conflictUpdatesFrag.len and not isEmptyFrag(st.conflictUpdatesFrag[i]):
            addFrag(result, st.conflictUpdatesFrag[i])
          else:
            addLit(result, s)

    if st.returningCols.len > 0:
      addLit(result, "\nRETURNING ")
      appendColumnExprsFrag(result, st.returningCols)

  of skUpdate:
    addLit(result, "UPDATE " & st.table & "\nSET ")
    for i, s in st.updateSets:
      if i > 0:
        addLit(result, ", ")
      if i < st.updateSetsFrag.len and not isEmptyFrag(st.updateSetsFrag[i]):
        addFrag(result, st.updateSetsFrag[i])
      else:
        addLit(result, s)

    if st.whereExpr.len > 0:
      addLit(result, "\nWHERE ")
      if not isEmptyFrag(st.whereFrag):
        addFrag(result, st.whereFrag)
      else:
        addLit(result, st.whereExpr)

    if st.returningCols.len > 0:
      addLit(result, "\nRETURNING ")
      appendColumnExprsFrag(result, st.returningCols)

  of skDelete:
    addLit(result, "DELETE FROM " & st.table)
    if st.whereExpr.len > 0:
      addLit(result, "\nWHERE ")
      if not isEmptyFrag(st.whereFrag):
        addFrag(result, st.whereFrag)
      else:
        addLit(result, st.whereExpr)

    if st.returningCols.len > 0:
      addLit(result, "\nRETURNING ")
      appendColumnExprsFrag(result, st.returningCols)

# =============================================================================
# 11. Object Schema Inspection & DDL Generation (createTableFrom)
# =============================================================================

proc nimFieldToSqlColType[F](): string =
  when isDatumOrContainsDatum[F]():
    {.error: "Raw PostgreSQL Datum (or container of Datum) cannot be used as a table column field type in createTableFrom.".}
  elif F is int or F is int32: "INTEGER"
  elif F is int64: "BIGINT"
  elif F is int16 or F is int8 or F is byte: "SMALLINT"
  elif F is uint or F is uint32: "BIGINT"
  elif F is uint64: "NUMERIC(20)"
  elif F is uint16 or F is uint8: "INTEGER"
  elif F is float or F is float64: "DOUBLE PRECISION"
  elif F is float32: "REAL"
  elif F is bool: "BOOLEAN"
  elif F is string or F is cstring: "TEXT"
  elif F is char: "CHAR(1)"
  elif F is JsonNode: "JSONB"
  elif F is distinct:
    when F is SqlIdent:
      {.error: "SqlIdent cannot be used as a table column field type in createTableFrom.".}
    else:
      nimFieldToSqlColType[distinctBase(F)]()
  elif typetraits.name(F) == "PgUuid": "UUID"
  elif typetraits.name(F) == "PgBytea": "BYTEA"
  elif typetraits.name(F) == "PgDate": "DATE"
  elif typetraits.name(F) == "PgTimestamp": "TIMESTAMP"
  elif typetraits.name(F) == "PgTimestampTz": "TIMESTAMPTZ"
  elif typetraits.name(F) == "PgInterval": "INTERVAL"
  elif typetraits.name(F) == "PgNumeric": "NUMERIC"
  elif F is seq:
    type ElemF = typeof(default(F)[0])
    when ElemF is int or ElemF is int32: "INTEGER[]"
    elif ElemF is int64: "BIGINT[]"
    elif ElemF is string: "TEXT[]"
    elif ElemF is float or ElemF is float64: "DOUBLE PRECISION[]"
    elif ElemF is bool: "BOOLEAN[]"
    elif ElemF is uint64: "NUMERIC(20)[]"
    elif ElemF is JsonNode: "JSONB[]"
    elif ElemF is distinct:
      when ElemF is SqlIdent:
        {.error: "seq[SqlIdent] cannot be used as a table column field type in createTableFrom.".}
      else:
        nimFieldToSqlColType[typeof(distinctBase(default(ElemF)))]() & "[]"
    elif typetraits.name(ElemF) == "PgUuid": "UUID[]"
    elif typetraits.name(ElemF) == "PgBytea": "BYTEA[]"
    elif typetraits.name(ElemF) == "PgDate": "DATE[]"
    elif typetraits.name(ElemF) == "PgTimestamp": "TIMESTAMP[]"
    elif typetraits.name(ElemF) == "PgTimestampTz": "TIMESTAMPTZ[]"
    elif typetraits.name(ElemF) == "PgInterval": "INTERVAL[]"
    elif typetraits.name(ElemF) == "PgNumeric": "NUMERIC[]"
    else: "TEXT[]"
  else: "TEXT"

proc columnDefsFromType*[T: object](primaryKey: string = "id"): seq[(string, string)] =
  ## Inspects properties of object type T and returns a sequence of (columnName, sqlTypeDef)
  result = @[]
  var dummy: T
  for name, val in fieldPairs(dummy):
    let colName = name
    var isNullable = false
    var sqlColType: string
    when typeof(val) is Option:
      isNullable = true
      sqlColType = nimFieldToSqlColType[typeof(val.get)]()
    else:
      sqlColType = nimFieldToSqlColType[typeof(val)]()

    var constraint = ""
    if colName.toLowerAscii == primaryKey.toLowerAscii:
      constraint = " PRIMARY KEY"
    elif not isNullable:
      constraint = " NOT NULL"

    result.add((colName, sqlColType & constraint))

proc getObjectTypeName*[T: object](): string =
  ## Returns normalized lowercase table name from object type T
  var dummy: T
  let rawName = $typeof(dummy)
  if "." in rawName:
    rawName.split('.')[^1].toLowerAscii
  else:
    rawName.toLowerAscii

proc columnsOf*[T: object](obj: T): seq[string] =
  ## Returns list of field/column names for object instance
  result = @[]
  for name, _ in fieldPairs(obj):
    result.add(name)

proc columnsOf*[T: object](t: typedesc[T]): seq[string] =
  ## Returns list of field/column names for object type
  var dummy: T
  columnsOf(dummy)

proc columnsOf*[T: object](): seq[string] =
  ## Returns list of field/column names for object type T
  var dummy: T
  columnsOf(dummy)

proc columnTypesOf*[T: object](obj: T): Table[string, string] =
  ## Returns table of (columnName -> sqlTypeDef) for object instance
  result = initTable[string, string]()
  for col in columnDefsFromType[T]():
    result[col[0]] = col[1]

proc columnTypesOf*[T: object](t: typedesc[T]): Table[string, string] =
  ## Returns table of (columnName -> sqlTypeDef) for object type
  var dummy: T
  columnTypesOf(dummy)

proc columnTypesOf*[T: object](): Table[string, string] =
  ## Returns table of (columnName -> sqlTypeDef) for object type T
  var dummy: T
  columnTypesOf(dummy)

proc tableFrom*[T: object](obj: T, tableName: string = "", alias: string = ""): TableRef =
  ## Creates a TableRef proxy using the object name or custom table name
  let targetTable = if tableName.len > 0: tableName else: getObjectTypeName[T]()
  table(targetTable, alias)

proc tableFrom*[T: object](t: typedesc[T], tableName: string = "", alias: string = ""): TableRef =
  ## Creates a TableRef proxy for typedesc[T]
  var dummy: T
  tableFrom(dummy, tableName, alias)

proc tableFrom*[T: object](tableName: string = "", alias: string = ""): TableRef =
  ## Creates a TableRef proxy for object type T
  var dummy: T
  tableFrom(dummy, tableName, alias)

proc createTableFromType*[T: object](tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): string =
  ## Generates a CREATE TABLE DDL SQL statement by inspecting properties of object type T
  let targetTable = if tableName.len > 0: tableName else: getObjectTypeName[T]()
  let cols = columnDefsFromType[T](primaryKey)
  var colDefs: seq[string] = @[]
  for col in cols:
    colDefs.add(quoteIdent(col[0]) & " " & col[1])

  var sql = "CREATE TABLE "
  if ifNotExists:
    sql.add("IF NOT EXISTS ")
  sql.add(quoteIdent(targetTable) & " (\n  " & colDefs.join(",\n  ") & "\n);")
  return sql

proc createTableFrom*[T: object](obj: T, tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): string =
  ## Generates a CREATE TABLE DDL statement by inspecting properties of an object instance
  createTableFromType[T](tableName, ifNotExists, primaryKey)

proc createTableFrom*[T: object](t: typedesc[T], tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): string =
  ## Generates a CREATE TABLE DDL statement by inspecting properties of a typedesc[T]
  createTableFromType[T](tableName, ifNotExists, primaryKey)

proc createTableFrom*[T: object](tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): string =
  ## Generates a CREATE TABLE DDL statement for object type T
  createTableFromType[T](tableName, ifNotExists, primaryKey)

proc insertFrom*[T: object](obj: T, tableName: string = ""): InsertValuesStep =
  ## Generates an INSERT INTO statement with columns and formatted/parameterized values extracted from object instance
  let targetTable = if tableName.len > 0: tableName else: getObjectTypeName[T]()
  var cols: seq[string] = @[]
  var vals: seq[string] = @[]
  var fragRow: seq[SqlFrag] = @[]

  for name, val in fieldPairs(obj):
    cols.add(name)
    let fSql = formatSqlValue(val)
    vals.add(fSql)
    when compiles(toQueryParamEx(val)):
      fragRow.add(toFrag(toQueryParamEx(val)))
    else:
      fragRow.add(litFrag(fSql))

  var insertStep = InsertInto(targetTable, cols)
  insertStep.state.insertRows.add(vals)
  insertStep.state.insertRowsFrag.add(fragRow)
  return InsertValuesStep(state: insertStep.state)

proc insertManyFrom*[T: object](objs: openArray[T], tableName: string = ""): InsertValuesStep =
  ## Generates an INSERT INTO statement with multiple formatted/parameterized rows from a collection of object instances.
  ## If the collection contains a single item, it delegates directly to insertFrom.
  if objs.len == 1:
    return insertFrom(objs[0], tableName)

  let targetTable = if tableName.len > 0: tableName else: getObjectTypeName[T]()
  let cols = columnsOf[T]()
  var insertStep = InsertInto(targetTable, cols)

  for obj in objs:
    var row: seq[string] = @[]
    var fragRow: seq[SqlFrag] = @[]
    for _, val in fieldPairs(obj):
      let fSql = formatSqlValue(val)
      row.add(fSql)
      when compiles(toQueryParamEx(val)):
        fragRow.add(toFrag(toQueryParamEx(val)))
      else:
        fragRow.add(litFrag(fSql))
    insertStep.state.insertRows.add(row)
    insertStep.state.insertRowsFrag.add(fragRow)

  return InsertValuesStep(state: insertStep.state)

proc insertFrom*[T: object](objs: openArray[T], tableName: string = ""): InsertValuesStep {.inline.} =
  ## Overload allowing openArray[T] seamlessly in insertFrom
  insertManyFrom[T](objs, tableName)
