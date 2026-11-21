## Arbitrary-Precision PostgreSQL Decimal (`numeric`) Type for pgxcrown
##
## Wraps PostgreSQL `Numeric` varlena directly and delegates arithmetic, rounding,
## and comparisons to PostgreSQL's exact decimal kernel (`utils/numeric.h`),
## avoiding IEEE-754 `float64` precision loss.

import std/[hashes, json, strutils, os]
import ./basic

const PgxCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxCHeadersDir).}

{.push header: "pgx_types.h".}
proc pgx_datum_get_numeric(d: Datum): pointer {.importc.}
proc pgx_numeric_get_datum(n: pointer): Datum {.importc.}
proc pgx_numeric_in(s: cstring): pointer {.importc.}
proc pgx_numeric_out(n: pointer): cstring {.importc.}
proc pgx_int64_to_numeric(v: int64): pointer {.importc.}
proc pgx_float8_to_numeric(v: float64): pointer {.importc.}
proc pgx_numeric_to_int64(n: pointer): int64 {.importc.}
proc pgx_numeric_to_float8(n: pointer): float64 {.importc.}
proc pgx_numeric_is_nan(n: pointer): bool {.importc.}
proc pgx_numeric_is_inf(n: pointer): bool {.importc.}
proc pgx_numeric_add(a, b: pointer, err: ptr bool): pointer {.importc.}
proc pgx_numeric_sub(a, b: pointer, err: ptr bool): pointer {.importc.}
proc pgx_numeric_mul(a, b: pointer, err: ptr bool): pointer {.importc.}
proc pgx_numeric_div(a, b: pointer, err: ptr bool): pointer {.importc.}
proc pgx_numeric_mod(a, b: pointer, err: ptr bool): pointer {.importc.}
proc pgx_numeric_cmp(a, b: pointer): int32 {.importc.}
proc pgx_numeric_abs(a: pointer): pointer {.importc.}
proc pgx_numeric_uminus(a: pointer): pointer {.importc.}
proc pgx_numeric_round(a: pointer, scale: int32): pointer {.importc.}
proc pgx_numeric_trunc(a: pointer, scale: int32): pointer {.importc.}
{.pop.}

type
  PgNumeric* = object
    ## Arbitrary-precision PostgreSQL `NUMERIC` value.
    ## Holds either a detoasted `Numeric` varlena pointer (`raw`) or a validated literal (`lit`).
    raw*: pointer
    lit*: string

proc validateNumericLiteral*(s: string): string {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Validates and canonicalizes a SQL `NUMERIC` literal string (accepts `NaN` / `±Infinity`).
  let t = s.strip()
  if t.len == 0:
    raise newException(ValueError, "Empty numeric literal")
  let lower = t.toLowerAscii()
  if lower == "nan":
    return "NaN"
  if lower in ["infinity", "+infinity", "inf", "+inf"]:
    return "Infinity"
  if lower in ["-infinity", "-inf"]:
    return "-Infinity"

  var i = 0
  if t[i] in {'+', '-'}:
    inc i
  var sawDigit = false
  while i < t.len and t[i] in '0'..'9':
    sawDigit = true
    inc i
  if i < t.len and t[i] == '.':
    inc i
    while i < t.len and t[i] in '0'..'9':
      sawDigit = true
      inc i
  if not sawDigit:
    raise newException(ValueError, "Invalid numeric literal: " & s)
  if i < t.len and t[i] in {'e', 'E'}:
    inc i
    if i < t.len and t[i] in {'+', '-'}:
      inc i
    var expDigits = 0
    while i < t.len and t[i] in '0'..'9':
      inc expDigits
      inc i
    if expDigits == 0:
      raise newException(ValueError, "Invalid exponent in numeric literal: " & s)
  if i != t.len:
    raise newException(ValueError, "Unexpected characters in numeric literal: " & s)
  t

proc initPgNumericZero*(): PgNumeric {.inline, noSideEffect, tags: [].} =
  ## Returns exact numeric `0`.
  PgNumeric(raw: nil, lit: "0")

proc pgNumeric*(s: string): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Constructs an arbitrary-precision `PgNumeric` from a validated decimal literal.
  PgNumeric(raw: nil, lit: validateNumericLiteral(s))

proc toPgNumeric*(v: int64 | int | int32 | int16 | int8 | uint32 | uint16 | uint8 | uint64): PgNumeric {.inline, noSideEffect, tags: [].} =
  PgNumeric(raw: nil, lit: $v)

proc toPgNumeric*(v: float64): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  PgNumeric(raw: nil, lit: validateNumericLiteral($v))

var
  pgxNumOutHook: proc(raw: pointer): string {.nimcall, noSideEffect, raises: [], tags: [].} = nil
  pgxNumIsNanHook: proc(raw: pointer): bool {.nimcall, noSideEffect, raises: [], tags: [].} = nil
  pgxNumIsInfHook: proc(raw: pointer): bool {.nimcall, noSideEffect, raises: [], tags: [].} = nil
  pgxNumCmpHook: proc(a, b: PgNumeric): int {.nimcall, noSideEffect, raises: [ValueError], tags: [].} = nil

proc `$`*(n: PgNumeric): string {.noSideEffect, raises: [], tags: [].} =
  if n.raw == nil:
    return if n.lit.len > 0: n.lit else: "0"
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if pgxNumOutHook != nil:
        return pgxNumOutHook(n.raw)
      return if n.lit.len > 0: n.lit else: "0"

proc `%`*(n: PgNumeric): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}:
    newJString($n)

# -----------------------------------------------------------------------------
# Pure-Nim Fallback Literal Normalization (for host unit tests without Postgres)
# -----------------------------------------------------------------------------

type
  DecimalRank = tuple[kind: int, neg: bool, exp: int, sig: string]

proc parseDecimalRank(rawLit: string): DecimalRank =
  let t = (if rawLit.len > 0: rawLit else: "0")
  if t == "NaN":
    return (3, false, 0, "")
  if t == "Infinity":
    return (2, false, 0, "")
  if t == "-Infinity":
    return (1, true, 0, "")

  var i = 0
  var neg = false
  if i < t.len and t[i] == '-':
    neg = true
    inc i
  elif i < t.len and t[i] == '+':
    inc i

  var intPart = ""
  while i < t.len and t[i] in '0'..'9':
    intPart.add(t[i])
    inc i
  var fracPart = ""
  if i < t.len and t[i] == '.':
    inc i
    while i < t.len and t[i] in '0'..'9':
      fracPart.add(t[i])
      inc i
  var expOffset = 0
  if i < t.len and t[i] in {'e', 'E'}:
    inc i
    var expSign = 1
    if i < t.len and t[i] == '-':
      expSign = -1
      inc i
    elif i < t.len and t[i] == '+':
      inc i
    var eVal = 0
    while i < t.len and t[i] in '0'..'9':
      eVal = eVal * 10 + (ord(t[i]) - ord('0'))
      inc i
    expOffset = expSign * eVal

  var digits = intPart & fracPart
  let fracLen = fracPart.len
  var firstNonZero = 0
  while firstNonZero < digits.len and digits[firstNonZero] == '0':
    inc firstNonZero
  if firstNonZero == digits.len:
    return (0, false, 0, "0")
  var lastNonZero = digits.len - 1
  while lastNonZero > firstNonZero and digits[lastNonZero] == '0':
    dec lastNonZero
  let sig = digits[firstNonZero .. lastNonZero]
  let sciExp = (digits.len - fracLen - 1 - firstNonZero) + expOffset
  (0, neg, sciExp, sig)

proc cmpNumericLiterals(aLit, bLit: string): int {.noSideEffect, tags: [].} =
  let a = parseDecimalRank(aLit)
  let b = parseDecimalRank(bLit)
  # Special Postgres ordering: -Infinity (1) < Finite (0/-1) < +Infinity (2) < NaN (3)
  proc pgOrderBucket(r: DecimalRank): int =
    case r.kind
    of 1: 0
    of 0: 1
    of 2: 2
    else: 3
  let ba = pgOrderBucket(a)
  let bb = pgOrderBucket(b)
  if ba != bb:
    return (if ba < bb: -1 else: 1)
  if a.kind != 0:
    return 0
  if a.sig == "0" and b.sig == "0":
    return 0
  if a.neg != b.neg:
    return (if a.neg: -1 else: 1)
  var magCmp = 0
  if a.exp != b.exp:
    magCmp = (if a.exp < b.exp: -1 else: 1)
  else:
    magCmp = system.cmp(a.sig, b.sig)
  if a.neg: -magCmp else: magCmp

# -----------------------------------------------------------------------------
# PostgreSQL Backend Materialization & Exact Decimal Arithmetic
# -----------------------------------------------------------------------------

proc materializeNumeric(n: PgNumeric): pointer {.noSideEffect, raises: [ValueError], tags: [].}

proc pgxNumOutImpl(raw: pointer): string {.nimcall, noSideEffect, raises: [], tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let cs = pgx_numeric_out(raw)
      if cs == nil:
        return "0"
      result = $cs
      pfree(cs)

proc pgxNumIsNanImpl(raw: pointer): bool {.nimcall, noSideEffect, raises: [], tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      pgx_numeric_is_nan(raw)

proc pgxNumIsInfImpl(raw: pointer): bool {.nimcall, noSideEffect, raises: [], tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      pgx_numeric_is_inf(raw)

proc pgxNumCmpImpl(a, b: PgNumeric): int {.nimcall, noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      int(pgx_numeric_cmp(pa, pb))

proc installNumericBackendHooks() {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if pgxNumOutHook == nil:
        pgxNumOutHook = pgxNumOutImpl
        pgxNumIsNanHook = pgxNumIsNanImpl
        pgxNumIsInfHook = pgxNumIsInfImpl
        pgxNumCmpHook = pgxNumCmpImpl

proc materializeNumeric(n: PgNumeric): pointer {.noSideEffect, raises: [ValueError], tags: [].} =
  installNumericBackendHooks()
  if n.raw != nil:
    return n.raw
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let litStr = if n.lit.len > 0: n.lit else: "0"
      let res = pgx_numeric_in(cstring(litStr))
      if res == nil:
        raise newException(ValueError, "Failed to materialize numeric value: " & litStr)
      res

proc isNaN*(n: PgNumeric): bool {.noSideEffect, tags: [].} =
  if n.raw == nil:
    return n.lit == "NaN"
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if pgxNumIsNanHook != nil:
        return pgxNumIsNanHook(n.raw)
      false

proc isInf*(n: PgNumeric): bool {.noSideEffect, tags: [].} =
  if n.raw == nil:
    return n.lit in ["Infinity", "-Infinity"]
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if pgxNumIsInfHook != nil:
        return pgxNumIsInfHook(n.raw)
      false

proc toPgNumericBackend*(v: int64): PgNumeric {.noSideEffect, tags: [].} =
  installNumericBackendHooks()
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      PgNumeric(raw: pgx_int64_to_numeric(v), lit: "")

proc toInt64*(n: PgNumeric): int64 {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a `PgNumeric` to `int64` via PostgreSQL `numeric_int8` (backend only).
  let p = materializeNumeric(n)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      pgx_numeric_to_int64(p)

proc toFloat64*(n: PgNumeric): float64 {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a `PgNumeric` to `float64` via PostgreSQL `numeric_float8` (backend only).
  let p = materializeNumeric(n)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      pgx_numeric_to_float8(p)

proc `+`*(a, b: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  var err = false
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let res = pgx_numeric_add(pa, pb, addr err)
      if err or res == nil:
        raise newException(ValueError, "Numeric addition overflow or invalid operand")
      PgNumeric(raw: res, lit: "")

proc `-`*(a, b: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  var err = false
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let res = pgx_numeric_sub(pa, pb, addr err)
      if err or res == nil:
        raise newException(ValueError, "Numeric subtraction overflow or invalid operand")
      PgNumeric(raw: res, lit: "")

proc `*`*(a, b: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  var err = false
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let res = pgx_numeric_mul(pa, pb, addr err)
      if err or res == nil:
        raise newException(ValueError, "Numeric multiplication overflow or invalid operand")
      PgNumeric(raw: res, lit: "")

proc divExact*(a, b: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Performs exact arbitrary-precision division via PostgreSQL's `numeric_div_opt_error`.
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  var err = false
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let res = pgx_numeric_div(pa, pb, addr err)
      if err or res == nil:
        raise newException(ValueError, "Numeric division by zero or overflow")
      PgNumeric(raw: res, lit: "")

proc `/`*(a, b: PgNumeric): PgNumeric {.inline, noSideEffect, raises: [ValueError], tags: [].} =
  divExact(a, b)

proc `mod`*(a, b: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  let pb = materializeNumeric(b)
  var err = false
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let res = pgx_numeric_mod(pa, pb, addr err)
      if err or res == nil:
        raise newException(ValueError, "Numeric modulo by zero or overflow")
      PgNumeric(raw: res, lit: "")

proc `-`*(a: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      PgNumeric(raw: pgx_numeric_uminus(pa), lit: "")

proc abs*(a: PgNumeric): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      PgNumeric(raw: pgx_numeric_abs(pa), lit: "")

proc round*(a: PgNumeric, scale: int32 = 0): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      PgNumeric(raw: pgx_numeric_round(pa, scale), lit: "")

proc trunc*(a: PgNumeric, scale: int32 = 0): PgNumeric {.noSideEffect, raises: [ValueError], tags: [].} =
  let pa = materializeNumeric(a)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      PgNumeric(raw: pgx_numeric_trunc(pa, scale), lit: "")

proc cmp*(a, b: PgNumeric): int {.noSideEffect, raises: [ValueError], tags: [].} =
  if a.raw == nil and b.raw == nil:
    return cmpNumericLiterals(a.lit, b.lit)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if pgxNumCmpHook != nil:
        return pgxNumCmpHook(a, b)
      cmpNumericLiterals($a, $b)

proc `==`*(a, b: PgNumeric): bool {.noSideEffect, tags: [].} =
  try:
    cmp(a, b) == 0
  except ValueError:
    false

proc `<`*(a, b: PgNumeric): bool {.noSideEffect, raises: [ValueError], tags: [].} =
  cmp(a, b) < 0

proc `<=`*(a, b: PgNumeric): bool {.noSideEffect, raises: [ValueError], tags: [].} =
  cmp(a, b) <= 0

proc hash*(n: PgNumeric): Hash {.noSideEffect, tags: [].} =
  let r = parseDecimalRank($n)
  var h: Hash = 0
  h = h !& r.kind !& ord(r.neg) !& r.exp
  h = h !& hash(r.sig)
  !$h

# Extraction & Return FFI for PostgreSQL Datum
proc getPgNumeric*(datum: Datum): PgNumeric {.inline, noSideEffect, tags: [].} =
  installNumericBackendHooks()
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if datum == 0:
        return initPgNumericZero()
      PgNumeric(raw: pgx_datum_get_numeric(datum), lit: "")

proc returnPgNumeric*(n: PgNumeric): Datum {.noSideEffect, raises: [ValueError], tags: [].} =
  let p = materializeNumeric(n)
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      pgx_numeric_get_datum(p)
