import std/[unittest, times, json]
import ../src/pgxcrown/datatypes/[temporal, numeric]

proc verifyImmutableEffectPurity(dStr, tsStr, numStr: string): string
    {.noSideEffect, forbids: [TimeEffect, IOEffect], raises: [ValueError], tags: [].} =
  let d = parsePgDate(dStr) + 1
  let dt = d.toDateTimeUtc()
  let roundD = dt.toPgDate()
  let ts = parsePgTimestampTz(tsStr)
  let t = ts.toTime()
  let roundTs = t.toPgTimestampTz()
  let iv = initPgInterval(days = 2, hours = 3, microseconds = 500_000)
  let dur = iv.toDuration()
  let roundIv = dur.toPgInterval()
  let n = pgNumeric(numStr)
  $roundD & "|" & $roundTs & "|" & $roundIv & "|" & $n

suite "Pgxcrown - Temporal Types & Arbitrary-Precision PgNumeric Suite":

  test "PgDate Postgres epoch, pre-1970, leap year, arithmetic, and infinity":
    let pgEpoch = initPgDate(2000, 1, 1)
    check pgEpoch.days == 0
    check $pgEpoch == "2000-01-01"

    let unixEpoch = initPgDate(1970, 1, 1)
    check unixEpoch.days == -10957
    check $unixEpoch == "1970-01-01"

    let leap = initPgDate(2024, 2, 29)
    check leap.year == 2024
    check leap.month == 2
    check leap.day == 29
    check $(leap + 1) == "2024-03-01"
    check $(leap - 1) == "2024-02-28"
    check (leap - pgEpoch) == 8825'i32
    check parsePgDate("2024-02-29") == leap
    check parsePgDate("1969-07-20") == initPgDate(1969, 7, 20)

    let posInf = pgDateInf()
    let negInf = pgDateNegInf()
    check posInf.isInfinity() and not posInf.isFinite()
    check negInf.isNegInfinity() and not negInf.isFinite()
    check $posInf == "infinity"
    check $negInf == "-infinity"
    check parsePgDate("INFINITY") == posInf
    check parsePgDate("-infinity") == negInf
    check negInf < unixEpoch and unixEpoch < pgEpoch and pgEpoch < posInf

    expect(ValueError):
      discard initPgDate(2023, 2, 29)
    expect(ValueError):
      discard initPgDate(2024, 4, 31)
    expect(ValueError):
      discard posInf.toYearMonthDay()
    expect(ValueError):
      discard parsePgDate("2024-13-01")

  test "PgTimestamp and PgTimestampTz microsecond precision, pre-1970 floor div, and timezone normalization":
    let pgMidnight = initPgTimestamp(2000, 1, 1, 0, 0, 0, 0)
    check pgMidnight.usec == 0'i64
    check $pgMidnight == "2000-01-01 00:00:00"

    let prePg = initPgTimestamp(1999, 12, 31, 23, 59, 59, 500_000)
    check prePg.usec == -500_000'i64
    check $prePg == "1999-12-31 23:59:59.5"
    check parsePgTimestamp("1999-12-31T23:59:59.500000") == prePg

    let preUnix = initPgTimestampTz(1969, 12, 31, 23, 59, 59, 123_456)
    let tPreUnix = preUnix.toTime()
    check tPreUnix.toUnix() == -1'i64
    check tPreUnix.nanosecond == 123_456_000
    check tPreUnix.toPgTimestampTz() == preUnix
    check $preUnix == "1969-12-31 23:59:59.123456+00"

    let dtUtc = preUnix.toDateTimeUtc()
    check dtUtc.year == 1969
    check ord(dtUtc.month) == 12
    check dtUtc.monthday == 31
    check dtUtc.hour == 23
    check dtUtc.minute == 59
    check dtUtc.second == 59
    check dtUtc.nanosecond == 123_456_000
    check dtUtc.toPgTimestampTz() == preUnix

    let tzParsed = parsePgTimestampTz("2024-06-15 14:30:00.25+02:30")
    check $tzParsed == "2024-06-15 12:00:00.25+00"
    check parsePgTimestampTz("2024-06-15T12:00:00.25Z") == tzParsed
    check parsePgTimestampTz("-infinity").isNegInfinity()
    check parsePgTimestamp("infinity").isInfinity()

    expect(ValueError):
      discard parsePgTimestamp("2024-01-01 12:00:00+02")

  test "PgInterval parsing, arithmetic, and std/times Duration & TimeInterval bridges":
    let iv1 = initPgInterval(years = 1, months = 2, days = 3, hours = 4, minutes = 5, seconds = 6, microseconds = 500_000)
    check iv1.months == 14'i32
    check iv1.days == 3'i32
    check iv1.usec == (4 * 3600 + 5 * 60 + 6) * 1_000_000'i64 + 500_000'i64
    check $iv1 == "1 year 2 mons 3 days 04:05:06.5"
    check parsePgInterval("1 year 2 mons 3 days 04:05:06.500000") == iv1
    check parsePgInterval("P1Y2M3DT4H5M6.5S") == iv1

    let ivZero = initPgInterval()
    check $ivZero == "00:00:00"
    check parsePgInterval("00:00:00") == ivZero

    let ivNeg = parsePgInterval("-02:30:00")
    check ivNeg.usec == -(2 * 3600 + 30 * 60) * 1_000_000'i64
    check $ivNeg == "-02:30:00"
    check parsePgInterval("@ 1 day 02:00:00 ago") == initPgInterval(days = -1, hours = -2)

    expect(ValueError):
      discard iv1.toDuration()

    let ivFixed = initPgInterval(days = 5, hours = 12, microseconds = 250_000)
    let dur = ivFixed.toDuration()
    check dur.toPgInterval() == ivFixed
    let ti = iv1.toTimeInterval()
    check ti.toPgInterval() == iv1

  test "PgNumeric exact literal validation, precision comparison, and special values":
    check validateNumericLiteral("  12345678901234567890123456789012345678.0123456789  ") ==
      "12345678901234567890123456789012345678.0123456789"
    check pgNumeric("10.50") == pgNumeric("10.5")
    check pgNumeric("1.23e2") == pgNumeric("123")
    check pgNumeric("-0.00") == initPgNumericZero()
    check pgNumeric("0.005") < pgNumeric("0.05")
    check pgNumeric("-1.25") < pgNumeric("-1.20")
    check pgNumeric("99999999999999999999999999999999.99") > pgNumeric("99999999999999999999999999999999.98")
    check pgNumeric("10.50").hash == pgNumeric("10.5").hash

    let nanVal = pgNumeric("nan")
    let posInf = pgNumeric("+inf")
    let negInf = pgNumeric("-INFINITY")
    check nanVal.isNaN()
    check posInf.isInf() and not posInf.isNaN()
    check negInf < pgNumeric("-999999999999999999999")
    check pgNumeric("999999999999999999999") < posInf
    check posInf < nanVal
    check %pgNumeric("42.125") == %"42.125"

    expect(ValueError):
      discard pgNumeric("")
    expect(ValueError):
      discard pgNumeric("12.34; DROP TABLE users")
    expect(ValueError):
      discard pgNumeric("1.2e")
    expect(ValueError):
      discard pgNumeric(".")

  test "Full {.immutable.} / noSideEffect / no-TimeEffect effect compatibility":
    let res = verifyImmutableEffectPurity("2024-02-28", "2024-02-29 12:00:00.5+00", "99999999999999999999.12345")
    check res == "2024-02-29|2024-02-29 12:00:00.5+00|2 days 03:00:00.5|99999999999999999999.12345"
