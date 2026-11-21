## Native PostgreSQL Temporal Data Types (`date`, `timestamp`, `timestamptz`, `interval`)
##
## Maps PostgreSQL `DateADT` (int32 days from 2000-01-01), `Timestamp` / `TimestampTz`
## (int64 microseconds from 2000-01-01 00:00:00), and `Interval` (16-byte months/days/usec)
## cleanly with deterministic `std/times` interoperability and full `{.immutable.}` purity.

import std/[times, hashes, json, strutils, os]
import ./basic

const PgxCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxCHeadersDir).}

{.push header: "pgx_types.h".}
proc pgx_datum_to_date(d: Datum): int32 {.importc.}
proc pgx_date_to_datum(v: int32): Datum {.importc.}
proc pgx_datum_to_timestamp(d: Datum): int64 {.importc.}
proc pgx_timestamp_to_datum(v: int64): Datum {.importc.}
proc pgx_datum_to_timestamptz(d: Datum): int64 {.importc.}
proc pgx_timestamptz_to_datum(v: int64): Datum {.importc.}
proc pgx_datum_to_interval(d: Datum, usec: ptr int64, day: ptr int32, month: ptr int32): bool {.importc.}
proc pgx_interval_to_datum(usec: int64, day: int32, month: int32): Datum {.importc.}
{.pop.}

const
  PostgresEpochJDate* = 2451545'i32
  UnixEpochJDate* = 2440588'i32
  PgUnixEpochDays* = PostgresEpochJDate - UnixEpochJDate ## 10957 days (1970-01-01 -> 2000-01-01)
  UsecsPerSec* = 1_000_000'i64
  UsecsPerMin* = 60_000_000'i64
  UsecsPerHour* = 3_600_000_000'i64
  UsecsPerDay* = 86_400_000_000'i64
  PgUnixEpochUsecs* = int64(PgUnixEpochDays) * UsecsPerDay ## 946684800000000 usec

  DateNoBegin* = low(int32)
  DateNoEnd* = high(int32)
  DtNoBegin* = low(int64)
  DtNoEnd* = high(int64)

type
  PgDate* = object
    ## PostgreSQL `date` (days since `2000-01-01`; extremes represent `-infinity` / `infinity`).
    days*: int32

  PgTimestamp* = object
    ## PostgreSQL `timestamp without time zone` (microseconds since `2000-01-01 00:00:00`).
    usec*: int64

  PgTimestampTz* = object
    ## PostgreSQL `timestamp with time zone` (UTC microseconds since `2000-01-01 00:00:00+00`).
    usec*: int64

  PgInterval* = object
    ## PostgreSQL `interval` (`usec` within day/hour/min/sec, plus separate `days` and `months`).
    usec*: int64
    days*: int32
    months*: int32

# -----------------------------------------------------------------------------
# Pure Floor Division / Civil Calendar Helpers (no TimeEffect or IOEffect)
# -----------------------------------------------------------------------------

proc floorDiv(a, b: int64): int64 {.inline, noSideEffect, tags: [].} =
  var q = a div b
  let r = a mod b
  if r != 0 and ((r < 0) != (b < 0)):
    dec q
  q

proc floorMod(a, b: int64): int64 {.inline, noSideEffect, tags: [].} =
  var r = a mod b
  if r != 0 and ((r < 0) != (b < 0)):
    r += b
  r

proc padDigits(val, width: int): string {.noSideEffect, tags: [].} =
  let s = $val
  if s.len >= width:
    return s
  result = newString(width)
  for i in 0 ..< (width - s.len):
    result[i] = '0'
  for i in 0 ..< s.len:
    result[width - s.len + i] = s[i]

proc date2j*(year, month, day: int): int32 {.noSideEffect, tags: [].} =
  ## Converts a proleptic Gregorian `(year, month, day)` date to PostgreSQL Julian day.
  var y = int64(year)
  var m = int64(month)
  if m > 2:
    m += 1
    y += 4800
  else:
    m += 13
    y += 4799
  let century = floorDiv(y, 100)
  var julian = y * 365 - 32167
  julian += floorDiv(y, 4) - century + floorDiv(century, 4)
  julian += (7834 * m) div 256 + int64(day)
  int32(julian)

proc j2date*(jd: int32): tuple[year, month, day: int] {.noSideEffect, tags: [].} =
  ## Converts a PostgreSQL Julian day to `(year, month, day)`.
  var julian = int64(jd) + 32044
  var quad = floorDiv(julian, 146097)
  let extra = (julian - quad * 146097) * 4 + 3
  julian += 60 + quad * 3 + floorDiv(extra, 146097)
  quad = floorDiv(julian, 1461)
  julian -= quad * 1461
  var y = (julian * 4) div 1461
  julian = (if y != 0: (julian + 305) mod 365 else: (julian + 306) mod 366) + 123
  y += quad * 4
  let year = int(y - 4800)
  quad = (julian * 2141) div 65536
  let day = int(julian - (7834 * quad) div 256)
  let month = int((quad + 10) mod 12 + 1)
  (year, month, day)

# -----------------------------------------------------------------------------
# Special Values & Constructors
# -----------------------------------------------------------------------------

proc pgDateInf*(): PgDate {.inline, noSideEffect, tags: [].} = PgDate(days: DateNoEnd)
proc pgDateNegInf*(): PgDate {.inline, noSideEffect, tags: [].} = PgDate(days: DateNoBegin)
proc isInfinity*(d: PgDate): bool {.inline, noSideEffect, tags: [].} = d.days == DateNoEnd
proc isNegInfinity*(d: PgDate): bool {.inline, noSideEffect, tags: [].} = d.days == DateNoBegin
proc isFinite*(d: PgDate): bool {.inline, noSideEffect, tags: [].} = d.days != DateNoBegin and d.days != DateNoEnd

proc pgTimestampInf*(): PgTimestamp {.inline, noSideEffect, tags: [].} = PgTimestamp(usec: DtNoEnd)
proc pgTimestampNegInf*(): PgTimestamp {.inline, noSideEffect, tags: [].} = PgTimestamp(usec: DtNoBegin)
proc isInfinity*(ts: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = ts.usec == DtNoEnd
proc isNegInfinity*(ts: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = ts.usec == DtNoBegin
proc isFinite*(ts: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = ts.usec != DtNoBegin and ts.usec != DtNoEnd

proc pgTimestampTzInf*(): PgTimestampTz {.inline, noSideEffect, tags: [].} = PgTimestampTz(usec: DtNoEnd)
proc pgTimestampTzNegInf*(): PgTimestampTz {.inline, noSideEffect, tags: [].} = PgTimestampTz(usec: DtNoBegin)
proc isInfinity*(ts: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = ts.usec == DtNoEnd
proc isNegInfinity*(ts: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = ts.usec == DtNoBegin
proc isFinite*(ts: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = ts.usec != DtNoBegin and ts.usec != DtNoEnd

proc initPgDate*(year, month, day: int): PgDate {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Constructs a `PgDate` from civil `(year, month, day)`, raising `ValueError` on invalid calendar dates.
  if month < 1 or month > 12 or day < 1 or day > 31 or year < -4713 or year > 5874897:
    raise newException(ValueError, "Date out of range: " & $year & "-" & $month & "-" & $day)
  let jd = date2j(year, month, day)
  if jd < 0 or jd >= 2147483494'i32:
    raise newException(ValueError, "Date outside PostgreSQL Julian bounds: " & $year & "-" & $month & "-" & $day)
  let checkYmd = j2date(jd)
  if checkYmd.year != year or checkYmd.month != month or checkYmd.day != day:
    raise newException(ValueError, "Invalid calendar date: " & $year & "-" & $month & "-" & $day)
  PgDate(days: jd - PostgresEpochJDate)

proc toYearMonthDay*(d: PgDate): tuple[year, month, day: int] {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Decomposes a finite `PgDate` into `(year, month, day)`; raises `ValueError` on `±infinity`.
  if not d.isFinite():
    raise newException(ValueError, "Cannot decompose infinite PgDate")
  j2date(d.days + PostgresEpochJDate)

proc year*(d: PgDate): int {.inline, noSideEffect, raises: [ValueError], tags: [].} = d.toYearMonthDay().year
proc month*(d: PgDate): int {.inline, noSideEffect, raises: [ValueError], tags: [].} = d.toYearMonthDay().month
proc day*(d: PgDate): int {.inline, noSideEffect, raises: [ValueError], tags: [].} = d.toYearMonthDay().day

proc validateTimeFields(hour, minute, second, microsecond: int) {.noSideEffect, raises: [ValueError], tags: [].} =
  if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 or
     microsecond < 0 or microsecond > 999_999:
    raise newException(ValueError, "Time component out of range")

proc encodeTimestampUsecs(year, month, day, hour, minute, second, microsecond: int): int64 {.noSideEffect, raises: [ValueError], tags: [].} =
  let d = initPgDate(year, month, day)
  validateTimeFields(hour, minute, second, microsecond)
  if year > 294276 or (year == 294276 and (month == 12 and day > 31)):
    raise newException(ValueError, "Timestamp year exceeds PostgreSQL 294276 AD limit")
  let timeUsecs = int64(hour) * UsecsPerHour + int64(minute) * UsecsPerMin +
                  int64(second) * UsecsPerSec + int64(microsecond)
  let res = int64(d.days) * UsecsPerDay + timeUsecs
  if res < -211_813_488_000_000_000'i64 or res >= 9_223_371_331_200_000_000'i64:
    raise newException(ValueError, "Timestamp outside PostgreSQL valid range")
  res

proc initPgTimestamp*(year, month, day: int, hour = 0, minute = 0, second = 0, microsecond = 0): PgTimestamp {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Constructs a `PgTimestamp` from civil calendar components.
  PgTimestamp(usec: encodeTimestampUsecs(year, month, day, hour, minute, second, microsecond))

proc initPgTimestampTz*(year, month, day: int, hour = 0, minute = 0, second = 0, microsecond = 0, utcOffsetSeconds = 0): PgTimestampTz {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Constructs a `PgTimestampTz` from components and a fixed UTC offset in seconds (converting to UTC).
  let localUsecs = encodeTimestampUsecs(year, month, day, hour, minute, second, microsecond)
  PgTimestampTz(usec: localUsecs - int64(utcOffsetSeconds) * UsecsPerSec)

proc decomposeUsecs(totalUsecs: int64): tuple[year, month, day, hour, minute, second, microsecond: int] {.noSideEffect, tags: [].} =
  let dayOffset = floorDiv(totalUsecs, UsecsPerDay)
  let timeOfDay = floorMod(totalUsecs, UsecsPerDay)
  let (y, m, d) = j2date(int32(dayOffset + int64(PostgresEpochJDate)))
  let secs = timeOfDay div UsecsPerSec
  let usec = int(timeOfDay mod UsecsPerSec)
  let hour = int(secs div 3600)
  let minute = int((secs mod 3600) div 60)
  let second = int(secs mod 60)
  (y, m, d, hour, minute, second, usec)

proc toComponents*(ts: PgTimestamp): tuple[year, month, day, hour, minute, second, microsecond: int] {.noSideEffect, raises: [ValueError], tags: [].} =
  if not ts.isFinite():
    raise newException(ValueError, "Cannot decompose infinite PgTimestamp")
  decomposeUsecs(ts.usec)

proc toComponents*(ts: PgTimestampTz): tuple[year, month, day, hour, minute, second, microsecond: int] {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Decomposes a finite `PgTimestampTz` in UTC.
  if not ts.isFinite():
    raise newException(ValueError, "Cannot decompose infinite PgTimestampTz")
  decomposeUsecs(ts.usec)

proc initPgInterval*(years = 0, months = 0, days = 0, hours: int64 = 0, minutes: int64 = 0, seconds: int64 = 0, microseconds: int64 = 0): PgInterval {.noSideEffect, tags: [].} =
  ## Constructs a `PgInterval` keeping months, days, and microseconds separate just like PostgreSQL.
  PgInterval(
    usec: hours * UsecsPerHour + minutes * UsecsPerMin + seconds * UsecsPerSec + microseconds,
    days: int32(days),
    months: int32(years * 12 + months)
  )

# -----------------------------------------------------------------------------
# Deterministic ISO-8601 Formatting & Parsing
# -----------------------------------------------------------------------------

proc formatYmd(year, month, day: int): string {.noSideEffect, tags: [].} =
  if year <= 0:
    let bcYear = -year + 1
    padDigits(bcYear, 4) & "-" & padDigits(month, 2) & "-" & padDigits(day, 2)
  else:
    padDigits(year, 4) & "-" & padDigits(month, 2) & "-" & padDigits(day, 2)

proc formatFracUsecs(usec: int): string {.noSideEffect, tags: [].} =
  if usec == 0:
    return ""
  var s = padDigits(usec, 6)
  var last = s.len - 1
  while last > 0 and s[last] == '0':
    dec last
  "." & s[0 .. last]

proc formatHms(hour, minute, second, usec: int): string {.noSideEffect, tags: [].} =
  padDigits(hour, 2) & ":" & padDigits(minute, 2) & ":" & padDigits(second, 2) & formatFracUsecs(usec)

proc `$`*(d: PgDate): string {.noSideEffect, tags: [].} =
  if d.isInfinity(): return "infinity"
  if d.isNegInfinity(): return "-infinity"
  let (y, m, day) = j2date(d.days + PostgresEpochJDate)
  result = formatYmd(y, m, day)
  if y <= 0:
    result.add(" BC")

proc `$`*(ts: PgTimestamp): string {.noSideEffect, tags: [].} =
  if ts.isInfinity(): return "infinity"
  if ts.isNegInfinity(): return "-infinity"
  let c = decomposeUsecs(ts.usec)
  result = formatYmd(c.year, c.month, c.day) & " " & formatHms(c.hour, c.minute, c.second, c.microsecond)
  if c.year <= 0:
    result.add(" BC")

proc `$`*(ts: PgTimestampTz): string {.noSideEffect, tags: [].} =
  ## Formats `PgTimestampTz` in canonical PostgreSQL UTC ISO representation (`+00`).
  if ts.isInfinity(): return "infinity"
  if ts.isNegInfinity(): return "-infinity"
  let c = decomposeUsecs(ts.usec)
  result = formatYmd(c.year, c.month, c.day) & " " & formatHms(c.hour, c.minute, c.second, c.microsecond) & "+00"
  if c.year <= 0:
    result.add(" BC")

proc `$`*(iv: PgInterval): string {.noSideEffect, tags: [].} =
  ## Formats `PgInterval` in canonical PostgreSQL interval syntax.
  var parts: seq[string] = @[]
  let years = int(iv.months div 12)
  let remMons = int(iv.months mod 12)
  if years != 0:
    parts.add($years & (if abs(years) == 1: " year" else: " years"))
  if remMons != 0:
    parts.add($remMons & (if abs(remMons) == 1: " mon" else: " mons"))
  if iv.days != 0:
    parts.add($iv.days & (if abs(iv.days) == 1: " day" else: " days"))
  if iv.usec != 0 or parts.len == 0:
    let neg = iv.usec < 0
    let absU = if neg: -iv.usec else: iv.usec
    let totalSecs = absU div UsecsPerSec
    let frac = int(absU mod UsecsPerSec)
    let hours = int(totalSecs div 3600)
    let mins = int((totalSecs mod 3600) div 60)
    let secs = int(totalSecs mod 60)
    let signPrefix = if neg: "-" else: ""
    parts.add(signPrefix & padDigits(hours, 2) & ":" & padDigits(mins, 2) & ":" & padDigits(secs, 2) & formatFracUsecs(frac))
  result = parts.join(" ")

proc `%`*(d: PgDate): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}: newJString($d)

proc `%`*(ts: PgTimestamp): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}: newJString($ts)

proc `%`*(ts: PgTimestampTz): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}: newJString($ts)

proc `%`*(iv: PgInterval): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}: newJString($iv)

proc parseIntField(s: string, startPos, maxDigits: int, nextPos: var int): int {.noSideEffect, raises: [ValueError], tags: [].} =
  var i = startPos
  var val = 0
  var count = 0
  while i < s.len and s[i] in '0'..'9' and (maxDigits <= 0 or count < maxDigits):
    val = val * 10 + (ord(s[i]) - ord('0'))
    inc i
    inc count
  if count == 0:
    raise newException(ValueError, "Expected integer digits in temporal string: " & s)
  nextPos = i
  val

proc parseDatePrefix(s: string, pos: var int): tuple[year, month, day: int] {.noSideEffect, raises: [ValueError], tags: [].} =
  var i = 0
  let year = parseIntField(s, i, 0, i)
  if i >= s.len or s[i] != '-':
    raise newException(ValueError, "Expected '-' after year in date: " & s)
  inc i
  let month = parseIntField(s, i, 2, i)
  if i >= s.len or s[i] != '-':
    raise newException(ValueError, "Expected '-' after month in date: " & s)
  inc i
  let day = parseIntField(s, i, 2, i)
  pos = i
  (year, month, day)

proc parseFractionUsecs(s: string, pos: var int): int {.noSideEffect, raises: [ValueError], tags: [].} =
  if pos >= s.len or s[pos] != '.':
    return 0
  inc pos
  var mult = 100_000
  var usecs = 0
  var count = 0
  while pos < s.len and s[pos] in '0'..'9':
    if mult > 0:
      usecs += (ord(s[pos]) - ord('0')) * mult
      mult = mult div 10
    inc pos
    inc count
  if count == 0:
    raise newException(ValueError, "Trailing '.' without fractional digits in timestamp: " & s)
  usecs

proc parsePgDate*(s: string): PgDate {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses an ISO date string (`YYYY-MM-DD`, `"infinity"`, `"-infinity"`, or `"YYYY-MM-DD BC"`).
  var t = s.strip()
  if t.len == 0:
    raise newException(ValueError, "Empty date string")
  let lower = t.toLowerAscii()
  if lower in ["infinity", "+infinity"]:
    return pgDateInf()
  if lower == "-infinity":
    return pgDateNegInf()
  var isBc = false
  if t.len >= 3 and (t.endsWith(" BC") or t.endsWith(" bc")):
    isBc = true
    t = t[0 .. ^4].strip()
  var pos = 0
  var (y, m, d) = parseDatePrefix(t, pos)
  if pos != t.len:
    raise newException(ValueError, "Unexpected trailing characters in date: " & s)
  if isBc:
    y = 1 - y
  initPgDate(y, m, d)

proc parseTimestampParts(s: string, allowTz: bool): tuple[usecs: int64, infState: int] {.noSideEffect, raises: [ValueError], tags: [].} =
  var t = s.strip()
  if t.len == 0:
    raise newException(ValueError, "Empty timestamp string")
  let lower = t.toLowerAscii()
  if lower in ["infinity", "+infinity"]:
    return (0'i64, 1)
  if lower == "-infinity":
    return (0'i64, -1)
  var isBc = false
  if t.len >= 3 and (t.endsWith(" BC") or t.endsWith(" bc")):
    isBc = true
    t = t[0 .. ^4].strip()
  var pos = 0
  var (year, month, day) = parseDatePrefix(t, pos)
  if isBc:
    year = 1 - year

  var hour, minute, second, frac = 0
  var tzOffsetSecs = 0
  if pos < t.len:
    if t[pos] notin {' ', 'T', 't'}:
      raise newException(ValueError, "Expected space or 'T' between date and time: " & s)
    inc pos
    while pos < t.len and t[pos] == ' ':
      inc pos
    hour = parseIntField(t, pos, 2, pos)
    if pos >= t.len or t[pos] != ':':
      raise newException(ValueError, "Expected ':' after hour in timestamp: " & s)
    inc pos
    minute = parseIntField(t, pos, 2, pos)
    if pos < t.len and t[pos] == ':':
      inc pos
      second = parseIntField(t, pos, 2, pos)
    frac = parseFractionUsecs(t, pos)

    if pos < t.len:
      while pos < t.len and t[pos] == ' ':
        inc pos
      if pos < t.len:
        if not allowTz:
          raise newException(ValueError, "Unexpected timezone suffix in PgTimestamp: " & s)
        if t[pos] in {'Z', 'z'}:
          inc pos
          tzOffsetSecs = 0
        elif t[pos] in {'+', '-'}:
          let sign = if t[pos] == '-': -1 else: 1
          inc pos
          let tzH = parseIntField(t, pos, 2, pos)
          var tzM = 0
          var tzS = 0
          if pos < t.len and (t[pos] == ':' or (t[pos] in '0'..'9')):
            if t[pos] == ':': inc pos
            tzM = parseIntField(t, pos, 2, pos)
            if pos < t.len and t[pos] == ':':
              inc pos
              tzS = parseIntField(t, pos, 2, pos)
          if tzH > 15 or tzM > 59 or tzS > 59:
            raise newException(ValueError, "Timezone offset out of range: " & s)
          tzOffsetSecs = sign * (tzH * 3600 + tzM * 60 + tzS)
        else:
          raise newException(ValueError, "Invalid timezone offset in timestamp: " & s)
  if pos != t.len:
    raise newException(ValueError, "Trailing characters in timestamp: " & s)
  let baseUsecs = encodeTimestampUsecs(year, month, day, hour, minute, second, frac)
  (baseUsecs - int64(tzOffsetSecs) * UsecsPerSec, 0)

proc parsePgTimestamp*(s: string): PgTimestamp {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses an ISO timestamp string without timezone (accepts `infinity` and `-infinity`).
  let (usecs, infState) = parseTimestampParts(s, allowTz = false)
  if infState > 0: return pgTimestampInf()
  if infState < 0: return pgTimestampNegInf()
  PgTimestamp(usec: usecs)

proc parsePgTimestampTz*(s: string): PgTimestampTz {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses an ISO timestamp with optional timezone (`Z`, `+HH`, `+HH:MM`, `-HH:MM:SS`) normalized to UTC.
  let (usecs, infState) = parseTimestampParts(s, allowTz = true)
  if infState > 0: return pgTimestampTzInf()
  if infState < 0: return pgTimestampTzNegInf()
  PgTimestampTz(usec: usecs)

proc parseHmsField(tok: string): int64 {.noSideEffect, raises: [ValueError], tags: [].} =
  var pos = 0
  var sign = 1'i64
  if tok[pos] == '-':
    sign = -1'i64
    inc pos
  elif tok[pos] == '+':
    inc pos
  let h = int64(parseIntField(tok, pos, 0, pos))
  if pos >= tok.len or tok[pos] != ':':
    raise newException(ValueError, "Expected ':' in interval time component: " & tok)
  inc pos
  let m = int64(parseIntField(tok, pos, 2, pos))
  var s = 0'i64
  var frac = 0'i64
  if pos < tok.len and tok[pos] == ':':
    inc pos
    s = int64(parseIntField(tok, pos, 2, pos))
    frac = int64(parseFractionUsecs(tok, pos))
  if pos != tok.len or m > 59 or s > 59:
    raise newException(ValueError, "Invalid interval time component: " & tok)
  sign * (h * UsecsPerHour + m * UsecsPerMin + s * UsecsPerSec + frac)

proc parseIsoInterval(s: string): PgInterval {.noSideEffect, raises: [ValueError], tags: [].} =
  var sign = 1
  var idx = 0
  if s[idx] == '-':
    sign = -1
    inc idx
  elif s[idx] == '+':
    inc idx
  if idx >= s.len or s[idx] notin {'P', 'p'}:
    raise newException(ValueError, "Invalid ISO interval: " & s)
  inc idx
  var inTime = false
  var months = 0
  var days = 0
  var usec = 0'i64
  var anyPart = false
  while idx < s.len:
    if s[idx] in {'T', 't'}:
      inTime = true
      inc idx
      continue
    var numSign = 1
    if s[idx] == '-':
      numSign = -1
      inc idx
    elif s[idx] == '+':
      inc idx
    let whole = parseIntField(s, idx, 0, idx)
    var frac = 0'i64
    if idx < s.len and s[idx] == '.':
      frac = int64(parseFractionUsecs(s, idx))
    if idx >= s.len:
      raise newException(ValueError, "Missing unit designator in ISO interval: " & s)
    let unit = s[idx]
    inc idx
    anyPart = true
    let unitSign = sign * numSign
    if not inTime:
      case unit
      of 'Y', 'y': months += unitSign * whole * 12
      of 'M', 'm': months += unitSign * whole
      of 'W', 'w': days += unitSign * whole * 7
      of 'D', 'd': days += unitSign * whole
      else: raise newException(ValueError, "Invalid date unit in ISO interval: " & s)
    else:
      case unit
      of 'H', 'h': usec += int64(unitSign) * int64(whole) * UsecsPerHour
      of 'M', 'm': usec += int64(unitSign) * int64(whole) * UsecsPerMin
      of 'S', 's': usec += int64(unitSign) * (int64(whole) * UsecsPerSec + frac)
      else: raise newException(ValueError, "Invalid time unit in ISO interval: " & s)
  if not anyPart:
    raise newException(ValueError, "Empty ISO interval: " & s)
  PgInterval(usec: usec, days: int32(days), months: int32(months))

proc parsePgInterval*(s: string): PgInterval {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses PostgreSQL `postgres`-style (`1 year 2 mons 3 days 04:05:06.5`) and ISO-8601 intervals.
  let trimmed = s.strip()
  if trimmed.len == 0:
    raise newException(ValueError, "Empty interval string")
  if trimmed[0] in {'P', 'p'} or (trimmed.len >= 2 and trimmed[0] in {'+', '-'} and trimmed[1] in {'P', 'p'}):
    return parseIsoInterval(trimmed)

  var tokens = trimmed.splitWhitespace()
  if tokens.len == 0:
    raise newException(ValueError, "Empty interval string")

  var startIdx = 0
  if tokens[0] == "@":
    inc startIdx
  var globalSign = 1
  if tokens.len > startIdx and tokens[^1].toLowerAscii() == "ago":
    globalSign = -1
    tokens.setLen(tokens.len - 1)
  if startIdx >= tokens.len:
    raise newException(ValueError, "Invalid interval string: " & s)

  var months = 0
  var days = 0
  var usec = 0'i64
  var i = startIdx
  while i < tokens.len:
    let tok = tokens[i]
    if ':' in tok:
      usec += parseHmsField(tok)
      inc i
    else:
      if i + 1 >= tokens.len:
        raise newException(ValueError, "Expected interval unit after value '" & tok & "' in: " & s)
      let val =
        try: parseBiggestInt(tok)
        except CatchableError:
          raise newException(ValueError, "Invalid numeric value in interval: " & tok)
      let unit = tokens[i + 1].toLowerAscii()
      if unit in ["y", "yr", "yrs", "year", "years"]:
        months += int(val) * 12
      elif unit in ["mon", "mons", "month", "months"]:
        months += int(val)
      elif unit in ["w", "wk", "wks", "week", "weeks"]:
        days += int(val) * 7
      elif unit in ["d", "day", "days"]:
        days += int(val)
      elif unit in ["h", "hr", "hrs", "hour", "hours"]:
        usec += int64(val) * UsecsPerHour
      elif unit in ["m", "min", "mins", "minute", "minutes"]:
        usec += int64(val) * UsecsPerMin
      elif unit in ["s", "sec", "secs", "second", "seconds"]:
        usec += int64(val) * UsecsPerSec
      elif unit in ["ms", "msec", "msecs", "millisecond", "milliseconds"]:
        usec += int64(val) * 1000'i64
      elif unit in ["us", "usec", "usecs", "microsecond", "microseconds"]:
        usec += int64(val)
      else:
        raise newException(ValueError, "Unsupported interval unit: " & tokens[i + 1])
      i += 2

  PgInterval(
    usec: int64(globalSign) * usec,
    days: int32(globalSign * days),
    months: int32(globalSign * months)
  )

# -----------------------------------------------------------------------------
# Arithmetic, Ordering & Hashing
# -----------------------------------------------------------------------------

proc `==`*(a, b: PgDate): bool {.inline, noSideEffect, tags: [].} = a.days == b.days
proc `<`*(a, b: PgDate): bool {.inline, noSideEffect, tags: [].} = a.days < b.days
proc `<=`*(a, b: PgDate): bool {.inline, noSideEffect, tags: [].} = a.days <= b.days
proc hash*(d: PgDate): Hash {.inline, noSideEffect, tags: [].} = hash(d.days)

proc `+`*(d: PgDate, deltaDays: int32): PgDate {.noSideEffect, raises: [ValueError], tags: [].} =
  if not d.isFinite():
    return d
  PgDate(days: d.days + deltaDays)

proc `-`*(d: PgDate, deltaDays: int32): PgDate {.noSideEffect, raises: [ValueError], tags: [].} =
  if not d.isFinite():
    return d
  PgDate(days: d.days - deltaDays)

proc `-`*(a, b: PgDate): int32 {.noSideEffect, raises: [ValueError], tags: [].} =
  if not a.isFinite() or not b.isFinite():
    raise newException(ValueError, "Cannot subtract infinite PgDate values")
  a.days - b.days

proc `==`*(a, b: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = a.usec == b.usec
proc `<`*(a, b: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = a.usec < b.usec
proc `<=`*(a, b: PgTimestamp): bool {.inline, noSideEffect, tags: [].} = a.usec <= b.usec
proc hash*(ts: PgTimestamp): Hash {.inline, noSideEffect, tags: [].} = hash(ts.usec)

proc addUsecs*(ts: PgTimestamp, deltaUsecs: int64): PgTimestamp {.noSideEffect, tags: [].} =
  if not ts.isFinite(): return ts
  PgTimestamp(usec: ts.usec + deltaUsecs)

proc diffUsecs*(a, b: PgTimestamp): int64 {.noSideEffect, raises: [ValueError], tags: [].} =
  if not a.isFinite() or not b.isFinite():
    raise newException(ValueError, "Cannot subtract infinite PgTimestamp values")
  a.usec - b.usec

proc `==`*(a, b: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = a.usec == b.usec
proc `<`*(a, b: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = a.usec < b.usec
proc `<=`*(a, b: PgTimestampTz): bool {.inline, noSideEffect, tags: [].} = a.usec <= b.usec
proc hash*(ts: PgTimestampTz): Hash {.inline, noSideEffect, tags: [].} = hash(ts.usec)

proc addUsecs*(ts: PgTimestampTz, deltaUsecs: int64): PgTimestampTz {.noSideEffect, tags: [].} =
  if not ts.isFinite(): return ts
  PgTimestampTz(usec: ts.usec + deltaUsecs)

proc diffUsecs*(a, b: PgTimestampTz): int64 {.noSideEffect, raises: [ValueError], tags: [].} =
  if not a.isFinite() or not b.isFinite():
    raise newException(ValueError, "Cannot subtract infinite PgTimestampTz values")
  a.usec - b.usec

proc `==`*(a, b: PgInterval): bool {.inline, noSideEffect, tags: [].} =
  a.usec == b.usec and a.days == b.days and a.months == b.months

proc `+`*(a, b: PgInterval): PgInterval {.inline, noSideEffect, tags: [].} =
  PgInterval(usec: a.usec + b.usec, days: a.days + b.days, months: a.months + b.months)

proc `-`*(a, b: PgInterval): PgInterval {.inline, noSideEffect, tags: [].} =
  PgInterval(usec: a.usec - b.usec, days: a.days - b.days, months: a.months - b.months)

proc `-`*(a: PgInterval): PgInterval {.inline, noSideEffect, tags: [].} =
  PgInterval(usec: -a.usec, days: -a.days, months: -a.months)

proc hash*(iv: PgInterval): Hash {.inline, noSideEffect, tags: [].} =
  var h: Hash = 0
  h = h !& hash(iv.usec)
  h = h !& hash(iv.days)
  h = h !& hash(iv.months)
  !$h

# -----------------------------------------------------------------------------
# Bridges to Nim std/times (zero TimeEffect leaks for {.immutable.} UDFs)
# -----------------------------------------------------------------------------

proc toTime*(ts: PgTimestampTz): Time {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a finite `PgTimestampTz` to `std/times.Time` (UTC instant).
  if not ts.isFinite():
    raise newException(ValueError, "Cannot convert infinite PgTimestampTz to std/times.Time")
  let unixUsecs = ts.usec + PgUnixEpochUsecs
  let secs = floorDiv(unixUsecs, UsecsPerSec)
  let remUsecs = floorMod(unixUsecs, UsecsPerSec)
  initTime(secs, NanosecondRange(remUsecs * 1000))

proc toPgTimestampTz*(t: Time): PgTimestampTz {.inline, noSideEffect, tags: [].} =
  ## Converts a `std/times.Time` to `PgTimestampTz` (microsecond resolution).
  let unixUsecs = t.toUnix() * UsecsPerSec + int64(t.nanosecond() div 1000)
  PgTimestampTz(usec: unixUsecs - PgUnixEpochUsecs)

proc toDateTimeUtc*(ts: PgTimestampTz): DateTime {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a finite `PgTimestampTz` to a UTC `std/times.DateTime`.
  let t = ts.toTime()
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      inZone(t, utc())

proc toDateTimeUtc*(ts: PgTimestamp): DateTime {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a finite `PgTimestamp` (interpreted in UTC) to `std/times.DateTime`.
  PgTimestampTz(usec: ts.usec).toDateTimeUtc()

proc toDateTimeUtc*(d: PgDate): DateTime {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a finite `PgDate` to a UTC `std/times.DateTime` at midnight `00:00:00`.
  if not d.isFinite():
    raise newException(ValueError, "Cannot convert infinite PgDate to DateTime")
  PgTimestampTz(usec: int64(d.days) * UsecsPerDay).toDateTimeUtc()

proc toPgTimestampTz*(dt: DateTime): PgTimestampTz {.noSideEffect, tags: [].} =
  ## Converts any timezone-aware `std/times.DateTime` to UTC `PgTimestampTz`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      toPgTimestampTz(dt.toTime())

proc toPgTimestamp*(dt: DateTime): PgTimestamp {.noSideEffect, tags: [].} =
  ## Extracts `(dt.year, dt.month, dt.monthday, dt.hour, dt.minute, dt.second, ns div 1000)` as `PgTimestamp`.
  initPgTimestamp(dt.year, ord(dt.month), dt.monthday, dt.hour, dt.minute, dt.second, dt.nanosecond div 1000)

proc toPgDate*(dt: DateTime): PgDate {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts the calendar date portion of a `DateTime` to `PgDate`.
  initPgDate(dt.year, ord(dt.month), dt.monthday)

proc toDuration*(iv: PgInterval): Duration {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Converts a month-free `PgInterval` (`months == 0`, 24h days) to `std/times.Duration`.
  if iv.months != 0:
    raise newException(ValueError, "Cannot convert PgInterval with non-zero months to exact Duration")
  initDuration(days = int64(iv.days), microseconds = iv.usec)

proc toPgInterval*(d: Duration): PgInterval {.noSideEffect, tags: [].} =
  ## Converts a `std/times.Duration` to `PgInterval` (whole days + sub-day microseconds).
  let totalUs = d.inMicroseconds()
  let dCount = totalUs div UsecsPerDay
  let remUs = totalUs mod UsecsPerDay
  PgInterval(usec: remUs, days: int32(dCount), months: 0'i32)

proc toTimeInterval*(iv: PgInterval): TimeInterval {.noSideEffect, tags: [].} =
  ## Converts a `PgInterval` to `std/times.TimeInterval`.
  let years = int(iv.months div 12)
  let mons = int(iv.months mod 12)
  let totalSecs = iv.usec div UsecsPerSec
  let us = int(iv.usec mod UsecsPerSec)
  let hrs = int(totalSecs div 3600)
  let mins = int((totalSecs mod 3600) div 60)
  let secs = int(totalSecs mod 60)
  initTimeInterval(microseconds = us, seconds = secs, minutes = mins, hours = hrs,
                   days = int(iv.days), months = mons, years = years)

proc toPgInterval*(ti: TimeInterval): PgInterval {.noSideEffect, tags: [].} =
  ## Converts a `std/times.TimeInterval` to `PgInterval`.
  let totalMonths = ti.years * 12 + ti.months
  let totalDays = ti.weeks * 7 + ti.days
  let totalUsecs = int64(ti.hours) * UsecsPerHour +
                   int64(ti.minutes) * UsecsPerMin +
                   int64(ti.seconds) * UsecsPerSec +
                   int64(ti.milliseconds) * 1000'i64 +
                   int64(ti.microseconds) +
                   int64(ti.nanoseconds div 1000)
  PgInterval(usec: totalUsecs, days: int32(totalDays), months: int32(totalMonths))

# -----------------------------------------------------------------------------
# Extraction & Return FFI for PostgreSQL Datum
# -----------------------------------------------------------------------------

proc getPgDate*(datum: Datum): PgDate {.noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    PgDate(days: pgx_datum_to_date(datum))

proc returnPgDate*(d: PgDate): Datum {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    pgx_date_to_datum(d.days)

proc getPgTimestamp*(datum: Datum): PgTimestamp {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    PgTimestamp(usec: pgx_datum_to_timestamp(datum))

proc returnPgTimestamp*(ts: PgTimestamp): Datum {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    pgx_timestamp_to_datum(ts.usec)

proc getPgTimestampTz*(datum: Datum): PgTimestampTz {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    PgTimestampTz(usec: pgx_datum_to_timestamptz(datum))

proc returnPgTimestampTz*(ts: PgTimestampTz): Datum {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    pgx_timestamptz_to_datum(ts.usec)

proc getPgInterval*(datum: Datum): PgInterval {.noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    if datum == 0:
      return PgInterval()
    var u: int64 = 0
    var d: int32 = 0
    var m: int32 = 0
    discard pgx_datum_to_interval(datum, addr u, addr d, addr m)
    PgInterval(usec: u, days: d, months: m)

proc returnPgInterval*(iv: PgInterval): Datum {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}: {.cast(tags: []).}:
    pgx_interval_to_datum(iv.usec, iv.days, iv.months)
