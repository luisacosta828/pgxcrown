import pgxcrown
import std/[json, options, strutils]

proc ex04_json_tag*(payload: JsonNode, tag: string = "verified"): JsonNode =
  result = payload.copy()
  result["status"] = %tag
  result["field_count"] = %(payload.len + 1)

proc ex04_json_get*(doc: JsonNode, key: string): Option[string] =
  if doc.kind == JObject and doc.hasKey(key) and doc[key].kind == JString:
    return some(doc[key].getStr)
  none(string)

proc ex04_uuid_info*(u: PgUuid): string {.immutable, parallelSafe.} =
  "ver=" & $u.version() & ",var=" & $u.variant() & ",str=" & $u

proc ex04_bytea_stats*(b: PgBytea): string {.immutable, parallelSafe.} =
  var nuls = 0
  var xorSum = 0'u8
  for item in b:
    if item == 0x00'u8:
      inc nuls
    xorSum = xorSum xor item
  "len=" & $b.len & ",nuls=" & $nuls & ",xor=" & toHex(xorSum, 2).toLowerAscii() & ",hex=" & $b

proc ex04_bytea_xor*(b: PgBytea, mask: int32 = 255): PgBytea {.immutable, parallelSafe.} =
  let m = byte(mask and 0xff'i32)
  var outBytes = newSeq[byte](b.len)
  for i in 0 ..< b.len:
    outBytes[i] = b[i] xor m
  toPgBytea(outBytes)

proc ex04_numeric_total*(price: PgNumeric, qty: PgNumeric, taxRate: PgNumeric): PgNumeric {.immutable, parallelSafe.} =
  let factor = pgNumeric("1") + taxRate
  (price * qty * factor).round(2)

proc ex04_date_shift*(d: PgDate, delta: int32): PgDate {.immutable, parallelSafe.} =
  d + delta

proc ex04_ts_add_seconds*(ts: PgTimestamp, secs: int64): PgTimestamp {.immutable, parallelSafe.} =
  ts.addUsecs(secs * UsecsPerSec)

proc ex04_tstz_norm_utc*(ts: PgTimestampTz): PgTimestampTz {.immutable, parallelSafe.} =
  if not ts.isFinite():
    return ts
  ts.toTime().toPgTimestampTz()

proc ex04_interval_add_us*(iv: PgInterval, extraUs: int64): PgInterval {.immutable, parallelSafe.} =
  iv + initPgInterval(microseconds = extraUs)
