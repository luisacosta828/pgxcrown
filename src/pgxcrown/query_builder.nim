## =============================================================================
## Type-Safe Step Builder Pattern for PostgreSQL Queries.
## Provides zero-string column DX, automatic SQL injection immunity,
## Common Table Expressions (CTEs), Window Functions, Lateral Joins,
## PostgreSQL UPSERT (ON CONFLICT), Set Operations, and Infix `as` Sugar.
## =============================================================================

import std/[strutils, sequtils, tables, macros, options, json]
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

proc quoteIdent*(s: string): string =
  ## Safely quotes PostgreSQL table or column identifiers ("table"."col"),
  ## and strips null bytes to prevent identifier injection.
  if s.len == 0: return ""
  if "." in s:
    var parts = s.split('.')
    for i in 0 ..< parts.len:
      if parts[i] != "*": parts[i] = "\"" & sanitizeIdentifierString(parts[i]) & "\""
    return parts.join(".")
  if s == "*": return "*"
  return "\"" & sanitizeIdentifierString(s) & "\""

proc isSafelyQuotedLiteral*(s: string): bool =
  ## Checks if string is already a valid, safely escaped single-quoted SQL literal
  if s.len < 2 or s[0] != '\'' or s[^1] != '\'':
    return false
  var i = 1
  while i < s.len - 1:
    if s[i] == '\0':
      return false
    elif s[i] == '\'':
      if i + 1 < s.len - 1 and s[i + 1] == '\'':
        i += 2
      else:
        return false # Unescaped quote inside literal -> unsafe!
    else:
      i += 1
  return true

proc isNumericLiteral*(s: string): bool =
  ## Checks if string is a pure numeric literal (integer or float)
  if s.len == 0: return false
  var hasDigit = false
  var hasDot = false
  var start = 0
  if s[0] in {'+', '-'}:
    start = 1
  if start >= s.len: return false
  for j in start ..< s.len:
    if s[j] in '0'..'9':
      hasDigit = true
    elif s[j] == '.' and not hasDot:
      hasDot = true
    else:
      return false
  return hasDigit

proc isKeywordLiteral*(s: string): bool =
  ## Checks if string is a safe SQL keyword literal
  let lower = s.toLowerAscii
  lower in ["true", "false", "null", "default"]

proc isArrayLiteral*(s: string): bool =
  ## Checks if string represents a genuine, safe PostgreSQL ARRAY[...] literal (e.g. from formatSqlValue)
  if s.len < 7 or not s.startsWith("ARRAY["):
    return false
  var inQuote = false
  var i = 6 # position immediately after "ARRAY["
  var bracketDepth = 1

  while i < s.len:
    let c = s[i]
    if c == '\0':
      return false
    elif inQuote:
      if c == '\'':
        if i + 1 < s.len and s[i + 1] == '\'':
          i += 1 # escaped quote inside literal
        else:
          inQuote = false
    else:
      if c == '\'':
        inQuote = true
      elif c == '[':
        bracketDepth += 1
      elif c == ']':
        bracketDepth -= 1
        if bracketDepth == 0:
          let rest = s[i + 1 .. ^1].strip()
          if rest.len == 0:
            return true
          if rest.startsWith("::") and rest.endsWith("[]"):
            let typeName = rest[2 .. ^3].strip().toLowerAscii
            return typeName in [
              "text", "varchar", "char", "integer", "int", "int4", "int8", "bigint",
              "smallint", "int2", "double precision", "float8", "float4", "real",
              "numeric", "decimal", "boolean", "bool", "json", "jsonb", "uuid",
              "timestamp", "timestamptz", "date", "bytea"
            ]
          return false
      elif c == ';':
        return false
      elif c == '-' and i + 1 < s.len and s[i + 1] == '-':
        return false
      elif c == '/' and i + 1 < s.len and s[i + 1] == '*':
        return false
    i += 1
  return false

proc safeSqlValue*(s: string): string =
  ## Automatically sanitizes any value for SQL query generation.
  ## Preserves already-safe balanced SQL string literals ('...'), pure numeric literals,
  ## standard keywords (TRUE, FALSE, NULL, DEFAULT), and PostgreSQL array literals (ARRAY[...]).
  ## Any other value is strictly escaped and enclosed in single quotes.
  if isSafelyQuotedLiteral(s):
    quoteLiteral(s[1 .. ^2].replace("''", "'"))
  elif isNumericLiteral(s) or isKeywordLiteral(s) or isArrayLiteral(s):
    s
  else:
    quoteLiteral(s)

type
  RawSql* = distinct string

proc raw*(s: string): RawSql = RawSql(s)
proc `$`*(r: RawSql): string = string(r)

type
  ParamKind* = enum
    pkInt, pkFloat, pkString, pkBool, pkNull, pkJson, pkRaw

  QueryParam* = object
    case kind*: ParamKind
    of pkInt: intVal*: int64
    of pkFloat: floatVal*: float64
    of pkString: strVal*: string
    of pkBool: boolVal*: bool
    of pkNull: discard
    of pkJson: jsonVal*: JsonNode
    of pkRaw: rawVal*: string

proc toParam*(v: int): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: int32): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: int64): QueryParam = QueryParam(kind: pkInt, intVal: v)
proc toParam*(v: int16): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: int8): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: uint): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: uint32): QueryParam = QueryParam(kind: pkInt, intVal: v.int64)
proc toParam*(v: uint64): QueryParam = QueryParam(kind: pkInt, intVal: cast[int64](v))
proc toParam*(v: float): QueryParam = QueryParam(kind: pkFloat, floatVal: v)
proc toParam*(v: float32): QueryParam = QueryParam(kind: pkFloat, floatVal: v.float64)
proc toParam*(v: string): QueryParam = QueryParam(kind: pkString, strVal: v)
proc toParam*(v: cstring): QueryParam = (if v == nil: QueryParam(kind: pkNull) else: QueryParam(kind: pkString, strVal: $v))
proc toParam*(v: bool): QueryParam = QueryParam(kind: pkBool, boolVal: v)
proc toParam*(v: JsonNode): QueryParam = (if v.isNil or v.kind == JNull: QueryParam(kind: pkNull) else: QueryParam(kind: pkJson, jsonVal: v))
proc toParam*(r: RawSql): QueryParam = QueryParam(kind: pkRaw, rawVal: string(r))
proc toParam*(p: QueryParam): QueryParam = p
proc toParam*[T](o: Option[T]): QueryParam = (if o.isSome: toParam(o.get) else: QueryParam(kind: pkNull))

converter toQueryParam*(v: int): QueryParam = toParam(v)
converter toQueryParam*(v: int32): QueryParam = toParam(v)
converter toQueryParam*(v: int64): QueryParam = toParam(v)
converter toQueryParam*(v: float): QueryParam = toParam(v)
converter toQueryParam*(v: float32): QueryParam = toParam(v)
converter toQueryParam*(v: bool): QueryParam = toParam(v)
converter toQueryParam*(v: string): QueryParam = toParam(v)
converter toQueryParam*(v: JsonNode): QueryParam = toParam(v)
converter toQueryParam*(r: RawSql): QueryParam = toParam(r)

proc `$`*(p: QueryParam): string =
  case p.kind
  of pkInt: $p.intVal
  of pkFloat: $p.floatVal
  of pkString: safeSqlValue(p.strVal)
  of pkBool: (if p.boolVal: "TRUE" else: "FALSE")
  of pkNull: "NULL"
  of pkJson: quoteLiteral($p.jsonVal)
  of pkRaw: p.rawVal

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

  SqlIdent* = distinct string

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
  SqlExpr* = object
    sql*: string

  ColumnExpr* = object
    expr*: string
    alias*: string

  WindowClause* = object
    partitionCols*: seq[string]
    orderCols*: seq[string]

  CaseWhenBuilder* = object
    whens*: seq[(string, string)] # (condition, result)
    elseExpr*: string

# Column to Column comparison (e.g. orders.user_id == users.id)
proc `==`*(a: ColumnRef, b: ColumnRef): SqlExpr = SqlExpr(sql: $a & " = " & $b)
proc `!=`*(a: ColumnRef, b: ColumnRef): SqlExpr = SqlExpr(sql: $a & " != " & $b)

# Column to Value comparison (automatically escaped / parameterized)
proc `==`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " = " & quoteLiteral(val))
proc `==`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " = " & $val)
proc `==`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " = " & $val)
proc `==`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " = " & $val)
proc `==`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " = " & $val)
proc `==`*(c: ColumnRef, val: bool): SqlExpr = SqlExpr(sql: $c & " = " & (if val: "TRUE" else: "FALSE"))
proc `==`*(c: ColumnRef, val: QueryParam): SqlExpr = SqlExpr(sql: $c & " = " & $val)
proc `==`*(c: ColumnRef, val: JsonNode): SqlExpr = SqlExpr(sql: $c & " = " & quoteLiteral($val))

proc `!=`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " != " & quoteLiteral(val))
proc `!=`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " != " & $val)
proc `!=`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " != " & $val)
proc `!=`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " != " & $val)
proc `!=`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " != " & $val)
proc `!=`*(c: ColumnRef, val: bool): SqlExpr = SqlExpr(sql: $c & " != " & (if val: "TRUE" else: "FALSE"))
proc `!=`*(c: ColumnRef, val: QueryParam): SqlExpr = SqlExpr(sql: $c & " != " & $val)

proc `>=`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " >= " & $val)
proc `>=`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " >= " & $val)
proc `>=`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " >= " & $val)
proc `>=`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " >= " & $val)
proc `>=`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " >= " & quoteLiteral(val))

proc `<=`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " <= " & $val)
proc `<=`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " <= " & $val)
proc `<=`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " <= " & $val)
proc `<=`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " <= " & $val)
proc `<=`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " <= " & quoteLiteral(val))

proc `>`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " > " & $val)
proc `>`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " > " & $val)
proc `>`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " > " & $val)
proc `>`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " > " & $val)
proc `>`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " > " & quoteLiteral(val))

proc `<`*(c: ColumnRef, val: int): SqlExpr = SqlExpr(sql: $c & " < " & $val)
proc `<`*(c: ColumnRef, val: int32): SqlExpr = SqlExpr(sql: $c & " < " & $val)
proc `<`*(c: ColumnRef, val: int64): SqlExpr = SqlExpr(sql: $c & " < " & $val)
proc `<`*(c: ColumnRef, val: float): SqlExpr = SqlExpr(sql: $c & " < " & $val)
proc `<`*(c: ColumnRef, val: string): SqlExpr = SqlExpr(sql: $c & " < " & quoteLiteral(val))

# String helper operators
proc like*(c: ColumnRef, pattern: string): SqlExpr = SqlExpr(sql: $c & " LIKE " & quoteLiteral(pattern))
proc ilike*(c: ColumnRef, pattern: string): SqlExpr = SqlExpr(sql: $c & " ILIKE " & quoteLiteral(pattern))
proc notLike*(c: ColumnRef, pattern: string): SqlExpr = SqlExpr(sql: $c & " NOT LIKE " & quoteLiteral(pattern))
proc notIlike*(c: ColumnRef, pattern: string): SqlExpr = SqlExpr(sql: $c & " NOT ILIKE " & quoteLiteral(pattern))

# NULL helpers
proc isNull*(c: ColumnRef): SqlExpr = SqlExpr(sql: $c & " IS NULL")
proc isNotNull*(c: ColumnRef): SqlExpr = SqlExpr(sql: $c & " IS NOT NULL")

# IN list helper
proc inList*(c: ColumnRef, items: openArray[string]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let quoted = items.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: $c & " IN (" & quoted & ")")

proc inList*(c: ColumnRef, items: openArray[int]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: $c & " IN (" & strItems & ")")

proc inList*(c: ColumnRef, items: openArray[int32]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: $c & " IN (" & strItems & ")")

proc inList*(c: ColumnRef, items: openArray[int64]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: $c & " IN (" & strItems & ")")

proc notInList*(c: ColumnRef, items: openArray[string]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "TRUE")
  let quoted = items.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: $c & " NOT IN (" & quoted & ")")

proc notInList*(c: ColumnRef, items: openArray[int]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "TRUE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: $c & " NOT IN (" & strItems & ")")

# BETWEEN helper
proc between*(c: ColumnRef, minVal, maxVal: int): SqlExpr =
  SqlExpr(sql: $c & " BETWEEN " & $minVal & " AND " & $maxVal)

proc between*(c: ColumnRef, minVal, maxVal: float): SqlExpr =
  SqlExpr(sql: $c & " BETWEEN " & $minVal & " AND " & $maxVal)

proc between*(c: ColumnRef, minVal, maxVal: string): SqlExpr =
  SqlExpr(sql: $c & " BETWEEN " & quoteLiteral(minVal) & " AND " & quoteLiteral(maxVal))

# ColumnExpr comparisons (for HAVING, JSON extractions, or computed columns)
proc `>`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " > " & $val)
proc `>`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " > " & $val)
proc `>`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " > " & $val)
proc `>`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " > " & $val)
proc `>`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " > " & quoteLiteral(val))

proc `<`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " < " & $val)
proc `<`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " < " & $val)
proc `<`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " < " & $val)
proc `<`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " < " & $val)
proc `<`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " < " & quoteLiteral(val))

proc `>=`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " >= " & $val)
proc `>=`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " >= " & $val)
proc `>=`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " >= " & $val)
proc `>=`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " >= " & $val)
proc `>=`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " >= " & quoteLiteral(val))

proc `<=`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " <= " & $val)
proc `<=`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " <= " & $val)
proc `<=`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " <= " & $val)
proc `<=`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " <= " & $val)
proc `<=`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " <= " & quoteLiteral(val))

proc `==`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(c: ColumnExpr, val: bool): SqlExpr = SqlExpr(sql: c.expr & " = " & (if val: "TRUE" else: "FALSE"))
proc `==`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " = " & quoteLiteral(val))
proc `==`*(c: ColumnExpr, val: QueryParam): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(c: ColumnExpr, val: ColumnRef): SqlExpr = SqlExpr(sql: c.expr & " = " & $val)
proc `==`*(a: ColumnExpr, b: ColumnExpr): SqlExpr = SqlExpr(sql: a.expr & " = " & b.expr)

proc `!=`*(c: ColumnExpr, val: int): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(c: ColumnExpr, val: int32): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(c: ColumnExpr, val: int64): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(c: ColumnExpr, val: float): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(c: ColumnExpr, val: bool): SqlExpr = SqlExpr(sql: c.expr & " != " & (if val: "TRUE" else: "FALSE"))
proc `!=`*(c: ColumnExpr, val: string): SqlExpr = SqlExpr(sql: c.expr & " != " & quoteLiteral(val))
proc `!=`*(c: ColumnExpr, val: QueryParam): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(c: ColumnExpr, val: ColumnRef): SqlExpr = SqlExpr(sql: c.expr & " != " & $val)
proc `!=`*(a: ColumnExpr, b: ColumnExpr): SqlExpr = SqlExpr(sql: a.expr & " != " & b.expr)

# String helper operators for ColumnExpr
proc like*(c: ColumnExpr, pattern: string): SqlExpr = SqlExpr(sql: c.expr & " LIKE " & quoteLiteral(pattern))
proc ilike*(c: ColumnExpr, pattern: string): SqlExpr = SqlExpr(sql: c.expr & " ILIKE " & quoteLiteral(pattern))
proc notLike*(c: ColumnExpr, pattern: string): SqlExpr = SqlExpr(sql: c.expr & " NOT LIKE " & quoteLiteral(pattern))
proc notIlike*(c: ColumnExpr, pattern: string): SqlExpr = SqlExpr(sql: c.expr & " NOT ILIKE " & quoteLiteral(pattern))

# NULL helpers for ColumnExpr
proc isNull*(c: ColumnExpr): SqlExpr = SqlExpr(sql: c.expr & " IS NULL")
proc isNotNull*(c: ColumnExpr): SqlExpr = SqlExpr(sql: c.expr & " IS NOT NULL")

# IN list helper for ColumnExpr
proc inList*(c: ColumnExpr, items: openArray[string]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let quoted = items.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: c.expr & " IN (" & quoted & ")")

proc inList*(c: ColumnExpr, items: openArray[int]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: c.expr & " IN (" & strItems & ")")

proc inList*(c: ColumnExpr, items: openArray[int32]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: c.expr & " IN (" & strItems & ")")

proc inList*(c: ColumnExpr, items: openArray[int64]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "FALSE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: c.expr & " IN (" & strItems & ")")

proc notInList*(c: ColumnExpr, items: openArray[string]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "TRUE")
  let quoted = items.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: c.expr & " NOT IN (" & quoted & ")")

proc notInList*(c: ColumnExpr, items: openArray[int]): SqlExpr =
  if items.len == 0: return SqlExpr(sql: "TRUE")
  let strItems = items.mapIt($it).join(", ")
  SqlExpr(sql: c.expr & " NOT IN (" & strItems & ")")

# BETWEEN helper for ColumnExpr
proc between*(c: ColumnExpr, minVal, maxVal: int): SqlExpr =
  SqlExpr(sql: c.expr & " BETWEEN " & $minVal & " AND " & $maxVal)

proc between*(c: ColumnExpr, minVal, maxVal: float): SqlExpr =
  SqlExpr(sql: c.expr & " BETWEEN " & $minVal & " AND " & $maxVal)

proc between*(c: ColumnExpr, minVal, maxVal: string): SqlExpr =
  SqlExpr(sql: c.expr & " BETWEEN " & quoteLiteral(minVal) & " AND " & quoteLiteral(maxVal))

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
  SqlExpr(sql: $c & " @> " & quoteLiteral($jsonVal))

proc containsJson*(c: ColumnRef, jsonVal: string): SqlExpr =
  ## JSON containment operator (@>) with raw string
  SqlExpr(sql: $c & " @> " & quoteLiteral(jsonVal))

proc containedByJson*(c: ColumnRef, jsonVal: JsonNode): SqlExpr =
  ## JSON contained-by operator (<@)
  SqlExpr(sql: $c & " <@ " & quoteLiteral($jsonVal))

proc containedByJson*(c: ColumnRef, jsonVal: string): SqlExpr =
  ## JSON contained-by operator (<@) with raw string
  SqlExpr(sql: $c & " <@ " & quoteLiteral(jsonVal))

proc hasJsonKey*(c: ColumnRef, key: string): SqlExpr =
  ## Checks if top-level key exists in JSON (?)
  SqlExpr(sql: $c & " ? " & quoteLiteral(key))

proc hasAnyJsonKey*(c: ColumnRef, keys: openArray[string]): SqlExpr =
  ## Checks if any top-level key exists in JSON (?|)
  let quoted = keys.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: $c & " ?| ARRAY[" & quoted & "]")

proc hasAllJsonKeys*(c: ColumnRef, keys: openArray[string]): SqlExpr =
  ## Checks if all top-level keys exist in JSON (?&)
  let quoted = keys.mapIt(quoteLiteral(it)).join(", ")
  SqlExpr(sql: $c & " ?& ARRAY[" & quoted & "]")

# Boolean logic
proc `and`*(a, b: SqlExpr): SqlExpr = SqlExpr(sql: a.sql & " AND " & b.sql)
proc `or`*(a, b: SqlExpr): SqlExpr = SqlExpr(sql: "(" & a.sql & " OR " & b.sql & ")")
proc `not`*(a: SqlExpr): SqlExpr = SqlExpr(sql: "NOT (" & a.sql & ")")

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

# SQL Aggregates
proc count*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: "COUNT(" & $c & ")", alias: "")
proc count*(s: string): ColumnExpr = ColumnExpr(expr: "COUNT(" & (if s == "*": "*" else: quoteIdent(s)) & ")", alias: "")
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
  CaseWhenBuilder(whens: @[(condition.sql, "")])

proc `then`*(builder: CaseWhenBuilder, value: string): CaseWhenBuilder =
  var b = builder
  b.whens[^1][1] = quoteLiteral(value)
  b

proc `then`*(builder: CaseWhenBuilder, value: int): CaseWhenBuilder =
  var b = builder
  b.whens[^1][1] = $value
  b

proc `when`*(builder: CaseWhenBuilder, condition: SqlExpr): CaseWhenBuilder =
  var b = builder
  b.whens.add((condition.sql, ""))
  b

proc elseEnd*(builder: CaseWhenBuilder, elseVal: string): ColumnExpr =
  var parts = @["CASE"]
  for w in builder.whens:
    parts.add("WHEN " & w[0] & " THEN " & w[1])
  parts.add("ELSE " & quoteLiteral(elseVal))
  parts.add("END")
  ColumnExpr(expr: parts.join(" "), alias: "")

proc elseEnd*(builder: CaseWhenBuilder, elseVal: int): ColumnExpr =
  var parts = @["CASE"]
  for w in builder.whens:
    parts.add("WHEN " & w[0] & " THEN " & w[1])
  parts.add("ELSE " & $elseVal)
  parts.add("END")
  ColumnExpr(expr: parts.join(" "), alias: "")

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

  SetOpKind* = enum
    sokNone, sokUnion, sokUnionAll, sokIntersect, sokExcept

  StatementKind* = enum
    skSelect, skValues, skInsert, skUpdate, skDelete

  CteClause* = object
    name*: string
    querySql*: string

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
    joins*: seq[JoinClause]
    whereExpr*: string
    groupBys*: seq[string]
    havingExpr*: string
    orderBys*: seq[string]
    limitVal*: int
    offsetVal*: int
    # Set Operations (UNION, INTERSECT, etc)
    setOpKind*: SetOpKind
    setOpTarget*: string
    # VALUES
    valuesRows*: seq[seq[string]]
    # INSERT / UPDATE / DELETE
    insertCols*: seq[string]
    insertRows*: seq[seq[string]]
    updateSets*: seq[string]
    returningCols*: seq[ColumnExpr]
    # PostgreSQL ON CONFLICT (UPSERT)
    conflictCols*: seq[string]
    conflictAction*: ConflictActionKind
    conflictUpdates*: seq[string]

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

# Forward declaration for stringifier
proc toSql*(st: QueryState): string
proc `$`*(step: ExecutableQuery): string = toSql(step.state)

# Column conversion helpers
proc colExpr*(expr: string, alias: string = ""): ColumnExpr = ColumnExpr(expr: expr, alias: alias)
proc toColumnExpr*(c: ColumnRef): ColumnExpr = ColumnExpr(expr: $c, alias: "")
proc toColumnExpr*(id: SqlIdent): ColumnExpr = ColumnExpr(expr: $id, alias: "")
proc toColumnExpr*(r: RawSql): ColumnExpr = ColumnExpr(expr: $r, alias: "")
proc toColumnExpr*(s: string): ColumnExpr = ColumnExpr(expr: quoteIdent(s), alias: "")
proc toColumnExpr*(n: int): ColumnExpr = ColumnExpr(expr: $n, alias: "")
proc toColumnExpr*(f: float): ColumnExpr = ColumnExpr(expr: $f, alias: "")
proc toColumnExpr*(c: ColumnExpr): ColumnExpr = c
proc toColumnExpr*(q: ExecutableQuery): ColumnExpr = ColumnExpr(expr: "(" & $q & ")", alias: "")

template `as`*(a: typed, b: string): ColumnExpr =
  colExpr((when compiles(toColumnExpr(a)): toColumnExpr(a).expr else: quoteIdent($a)), b)

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
      colExpr((when compiles(toColumnExpr(`col`)): toColumnExpr(`col`).expr else: quoteIdent($`col`)), $`al`)
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
    ctes: @[CteClause(name: quoteIdent(name), querySql: $subquery)],
    limitVal: -1, 
    offsetVal: -1
  )
  WithStep(state: st)

proc AndWith*(step: WithStep, name: string, subquery: ExecutableQuery): WithStep =
  step.state.ctes.add(CteClause(name: quoteIdent(name), querySql: $subquery))
  step

# =============================================================================
# 7. Step Builder Methods (FROM, JOINS, WHERE, GROUP BY, ORDER BY, LIMIT, OFFSET)
# =============================================================================
proc From*(step: SelectStep, t: TableRef): FromStep =
  step.state.table = quoteIdent(t.rawTable)
  step.state.alias = if t.rawAlias.len > 0: quoteIdent(t.rawAlias) else: ""
  FromStep(state: step.state)

proc From*(step: SelectStep, table: string, alias: string = ""): FromStep =
  step.From(TableRef(rawTable: table, rawAlias: alias))

proc From*(step: SelectStep, subquery: ExecutableQuery, alias: string): FromStep =
  step.state.table = "(" & $subquery & ")"
  step.state.alias = quoteIdent(alias)
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
    alias: quoteIdent(alias)
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
  step.state.joins.add(JoinClause(kind: jkCross, isLateral: true, table: "(" & $subquery & ")", alias: quoteIdent(alias)))
  step

# ON
proc On*(step: JoinStep, expr: SqlExpr): FromStep =
  var j = step.currentJoin
  j.onCondition = expr.sql
  step.state.joins.add(j)
  FromStep(state: step.state)

proc On*(step: JoinStep, condition: string): FromStep =
  step.On(SqlExpr(sql: condition))

# WHERE
proc Where*(step: FromStep, expr: SqlExpr): WhereStep =
  step.state.whereExpr = expr.sql
  WhereStep(state: step.state)

proc And*(step: WhereStep, expr: SqlExpr): WhereStep =
  step.state.whereExpr.add(" AND " & expr.sql)
  step

proc Or*(step: WhereStep, expr: SqlExpr): WhereStep =
  step.state.whereExpr = "(" & step.state.whereExpr & " OR " & expr.sql & ")"
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

proc Having*(step: GroupByStep, expr: SqlExpr): HavingStep =
  step.state.havingExpr = expr.sql
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
  SelectStep(state: st)

proc UnionAll*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokUnionAll
  st.setOpTarget = $q2
  SelectStep(state: st)

proc Intersect*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokIntersect
  st.setOpTarget = $q2
  SelectStep(state: st)

proc Except*[T1: ExecutableQuery, T2: ExecutableQuery](q1: T1, q2: T2): SelectStep =
  let st = q1.state
  st.setOpKind = sokExcept
  st.setOpTarget = $q2
  SelectStep(state: st)

# =============================================================================
# 9. PostgreSQL Standalone VALUES & Rows
# =============================================================================
proc Values*(rows: varargs[seq[string]]): ValuesStep =
  var sanitizedRows: seq[seq[string]] = @[]
  for row in rows:
    sanitizedRows.add(row.mapIt(safeSqlValue(it)))
  let st = QueryState(kind: skValues, valuesRows: sanitizedRows, limitVal: -1, offsetVal: -1)
  ValuesStep(state: st)

proc Row*(params: varargs[QueryParam, toQueryParam]): seq[string] =
  var res: seq[string] = @[]
  for p in params:
    res.add($p)
  res

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

proc Values*(step: InsertStep or InsertValuesStep, params: varargs[QueryParam, toQueryParam]): InsertValuesStep =
  var formattedRow: seq[string] = @[]
  for p in params:
    formattedRow.add($p)
  step.state.insertRows.add(formattedRow)
  InsertValuesStep(state: step.state)

proc Values*(step: InsertStep or InsertValuesStep, vals: openArray[string]): InsertValuesStep =
  var formattedRow: seq[string] = @[]
  for v in vals:
    formattedRow.add(safeSqlValue(v))
  step.state.insertRows.add(formattedRow)
  InsertValuesStep(state: step.state)

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

proc DoUpdate*(step: ConflictStep, exprs: varargs[SqlExpr]): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  for e in exprs:
    step.state.conflictUpdates.add(cleanSetExpr(e.sql))
  InsertValuesStep(state: step.state)

proc DoUpdate*(step: ConflictStep, col: ColumnRef, val: QueryParam): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  step.state.conflictUpdates.add(quoteIdent(col.rawCol) & " = " & $val)
  InsertValuesStep(state: step.state)

proc DoUpdate*(step: ConflictStep, sets: varargs[string]): InsertValuesStep =
  step.state.conflictAction = cakDoUpdate
  for s in sets:
    step.state.conflictUpdates.add(cleanSetExpr(s))
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
  UpdateSetStep(state: step.state)

proc Set*(step: UpdateStep or UpdateSetStep, col: ColumnRef, val: QueryParam): UpdateSetStep =
  step.state.updateSets.add(quoteIdent(col.rawCol) & " = " & $val)
  UpdateSetStep(state: step.state)

proc Set*(step: UpdateStep or UpdateSetStep, sets: varargs[string]): UpdateSetStep =
  for s in sets:
    step.state.updateSets.add(cleanSetExpr(s))
  UpdateSetStep(state: step.state)

proc Where*(step: UpdateSetStep, expr: SqlExpr): UpdateWhereStep =
  step.state.whereExpr = expr.sql
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
# 11. SQL Generator
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

# =============================================================================
# 11. Object Schema Inspection & DDL Generation (createTableFrom)
# =============================================================================

proc formatSqlValue*[T](val: T): string =
  ## Safely serializes a Nim field value into a SQL literal for INSERT/UPDATE statements
  when T is int or T is int32 or T is int64 or T is int16 or T is int8 or T is byte:
    $val
  elif T is uint or T is uint32 or T is uint64 or T is uint16 or T is uint8:
    $val
  elif T is float or T is float64 or T is float32:
    $val
  elif T is bool:
    if val: "TRUE" else: "FALSE"
  elif T is string or T is cstring:
    quoteLiteral($val)
  elif T is char:
    quoteLiteral($val)
  elif T is JsonNode:
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
      else: "ARRAY[" & val.mapIt($it).join(", ") & "]"
    elif typeof(val[0]) is bool:
      if val.len == 0: "ARRAY[]::boolean[]"
      else: "ARRAY[" & val.mapIt(if it: "TRUE" else: "FALSE").join(", ") & "]"
    elif typeof(val[0]) is JsonNode:
      if val.len == 0: "ARRAY[]::jsonb[]"
      else: "ARRAY[" & val.mapIt(quoteLiteral($it)).join(", ") & "]::jsonb[]"
    else:
      quoteLiteral($val)
  else:
    quoteLiteral($val)

proc columnDefsFromType*[T: object](primaryKey: string = "id"): seq[(string, string)] =
  ## Inspects properties of object type T and returns a sequence of (columnName, sqlTypeDef)
  result = @[]
  var dummy: T
  for name, val in fieldPairs(dummy):
    let colName = name
    var sqlColType: string
    var isNullable = false

    when typeof(val) is int or typeof(val) is int32:
      sqlColType = "INTEGER"
    elif typeof(val) is int64:
      sqlColType = "BIGINT"
    elif typeof(val) is int16 or typeof(val) is int8 or typeof(val) is byte:
      sqlColType = "SMALLINT"
    elif typeof(val) is uint or typeof(val) is uint32:
      sqlColType = "BIGINT"
    elif typeof(val) is uint64:
      sqlColType = "NUMERIC(20)"
    elif typeof(val) is uint16 or typeof(val) is uint8:
      sqlColType = "INTEGER"
    elif typeof(val) is float or typeof(val) is float64:
      sqlColType = "DOUBLE PRECISION"
    elif typeof(val) is float32:
      sqlColType = "REAL"
    elif typeof(val) is bool:
      sqlColType = "BOOLEAN"
    elif typeof(val) is string or typeof(val) is cstring:
      sqlColType = "TEXT"
    elif typeof(val) is char:
      sqlColType = "CHAR(1)"
    elif typeof(val) is JsonNode:
      sqlColType = "JSONB"
    elif typeof(val) is seq[int] or typeof(val) is seq[int32]:
      sqlColType = "INTEGER[]"
    elif typeof(val) is seq[int64]:
      sqlColType = "BIGINT[]"
    elif typeof(val) is seq[string]:
      sqlColType = "TEXT[]"
    elif typeof(val) is seq[float] or typeof(val) is seq[float64]:
      sqlColType = "DOUBLE PRECISION[]"
    elif typeof(val) is seq[bool]:
      sqlColType = "BOOLEAN[]"
    elif typeof(val) is seq[JsonNode]:
      sqlColType = "JSONB[]"
    elif typeof(val) is Option:
      isNullable = true
      when typeof(val.get) is int or typeof(val.get) is int32:
        sqlColType = "INTEGER"
      elif typeof(val.get) is int64:
        sqlColType = "BIGINT"
      elif typeof(val.get) is int16 or typeof(val.get) is int8:
        sqlColType = "SMALLINT"
      elif typeof(val.get) is float or typeof(val.get) is float64:
        sqlColType = "DOUBLE PRECISION"
      elif typeof(val.get) is float32:
        sqlColType = "REAL"
      elif typeof(val.get) is bool:
        sqlColType = "BOOLEAN"
      elif typeof(val.get) is string or typeof(val.get) is cstring:
        sqlColType = "TEXT"
      elif typeof(val.get) is char:
        sqlColType = "CHAR(1)"
      elif typeof(val.get) is JsonNode:
        sqlColType = "JSONB"
      elif typeof(val.get) is seq[string]:
        sqlColType = "TEXT[]"
      elif typeof(val.get) is seq[int] or typeof(val.get) is seq[int32]:
        sqlColType = "INTEGER[]"
      elif typeof(val.get) is seq[int64]:
        sqlColType = "BIGINT[]"
      elif typeof(val.get) is seq[float] or typeof(val.get) is seq[float64]:
        sqlColType = "DOUBLE PRECISION[]"
      elif typeof(val.get) is seq[bool]:
        sqlColType = "BOOLEAN[]"
      elif typeof(val.get) is seq[JsonNode]:
        sqlColType = "JSONB[]"
      else:
        sqlColType = "TEXT"
    else:
      sqlColType = "TEXT"

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
  ## Generates an INSERT INTO statement with columns and formatted values extracted from object instance
  let targetTable = if tableName.len > 0: tableName else: getObjectTypeName[T]()
  var cols: seq[string] = @[]
  var vals: seq[string] = @[]

  for name, val in fieldPairs(obj):
    cols.add(name)
    vals.add(formatSqlValue(val))

  var insertStep = InsertInto(targetTable, cols)
  insertStep.Values(vals)
