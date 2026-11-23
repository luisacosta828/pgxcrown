## Native 16-Byte Zero-Copy UUID Data Type (`uuid`) for PostgreSQL in pgxcrown
##
## Represents PostgreSQL `pg_uuid_t` directly as a 16-byte POD value object,
## compatible with immutable UDFs, composite types, arrays, and shared memory.

import std/[hashes, json, os]
import ./basic

const PgxCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxCHeadersDir).}

{.push header: "pgx_types.h".}
proc pgx_datum_to_uuid_bytes(d: Datum, out16: ptr uint8): bool {.importc.}
proc pgx_uuid_bytes_to_datum(in16: ptr uint8): Datum {.importc.}
{.pop.}

type
  PgUuid* = object
    ## Fixed 16-byte big-endian RFC 4122 / PostgreSQL `uuid` value.
    bytes*: array[16, uint8]

const
  HexLower = "0123456789abcdef"

proc nilUuid*(): PgUuid {.inline, noSideEffect, tags: [].} =
  ## Returns the all-zero nil UUID (`00000000-0000-0000-0000-000000000000`).
  PgUuid()

proc isNilUuid*(u: PgUuid): bool {.inline, noSideEffect, tags: [].} =
  for b in u.bytes:
    if b != 0'u8:
      return false
  return true

proc initPgUuid*(bytes: array[16, uint8]): PgUuid {.inline, noSideEffect, tags: [].} =
  ## Wraps a 16-byte big-endian UUID array into `PgUuid`.
  PgUuid(bytes: bytes)

proc initPgUuid*(bytes: openArray[byte]): PgUuid {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Constructs a `PgUuid` from a 16-byte slice; raises `ValueError` if length != 16.
  if bytes.len != 16:
    raise newException(ValueError, "UUID requires exactly 16 bytes, got " & $bytes.len)
  for i in 0 ..< 16:
    result.bytes[i] = bytes[i]

proc parseHexNibble(ch: char): int {.inline, noSideEffect, raises: [ValueError], tags: [].} =
  case ch
  of '0'..'9': ord(ch) - ord('0')
  of 'a'..'f': ord(ch) - ord('a') + 10
  of 'A'..'F': ord(ch) - ord('A') + 10
  else:
    raise newException(ValueError, "Invalid hexadecimal character in UUID: '" & ch & "'")

proc parsePgUuid*(s: openArray[char]): PgUuid {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses a canonical (`8-4-4-4-12`), braced (`{...}`), or compact 32-hex UUID string.
  var lo = 0
  var hi = s.len - 1
  while lo <= hi and s[lo] in {' ', '\t', '\r', '\n'}:
    inc lo
  while hi >= lo and s[hi] in {' ', '\t', '\r', '\n'}:
    dec hi

  let span = hi - lo + 1
  if span == 38 and s[lo] == '{' and s[hi] == '}':
    inc lo
    dec hi
  elif span notin {32, 36}:
    raise newException(ValueError, "Invalid UUID string length: expected 32 or 36 hex format")

  let trimmedLen = hi - lo + 1
  if trimmedLen == 36:
    if s[lo + 8] != '-' or s[lo + 13] != '-' or s[lo + 18] != '-' or s[lo + 23] != '-':
      raise newException(ValueError, "Invalid hyphen placement in UUID string")
    var byteIdx = 0
    var pos = lo
    while byteIdx < 16:
      if pos == lo + 8 or pos == lo + 13 or pos == lo + 18 or pos == lo + 23:
        inc pos
        continue
      let hiNib = parseHexNibble(s[pos])
      let loNib = parseHexNibble(s[pos + 1])
      result.bytes[byteIdx] = uint8((hiNib shl 4) or loNib)
      inc byteIdx
      pos += 2
  elif trimmedLen == 32:
    for byteIdx in 0 ..< 16:
      let pos = lo + byteIdx * 2
      let hiNib = parseHexNibble(s[pos])
      let loNib = parseHexNibble(s[pos + 1])
      result.bytes[byteIdx] = uint8((hiNib shl 4) or loNib)
  else:
    raise newException(ValueError, "Invalid UUID format")

proc parsePgUuid*(s: string): PgUuid {.inline, noSideEffect, raises: [ValueError], tags: [].} =
  parsePgUuid(s.toOpenArray(0, s.len - 1))

proc toString*(u: PgUuid): string {.noSideEffect, tags: [].} =
  ## Formats `PgUuid` in canonical PostgreSQL lowercase `8-4-4-4-12` representation.
  result = newString(36)
  var pos = 0
  for i in 0 ..< 16:
    if i in {4, 6, 8, 10}:
      result[pos] = '-'
      inc pos
    let v = int(u.bytes[i])
    result[pos] = HexLower[(v shr 4) and 0xF]
    result[pos + 1] = HexLower[v and 0xF]
    pos += 2

proc `$`*(u: PgUuid): string {.inline, noSideEffect, tags: [].} =
  toString(u)

proc `%`*(u: PgUuid): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}:
    newJString(toString(u))

proc version*(u: PgUuid): int {.inline, noSideEffect, tags: [].} =
  ## Returns the RFC 4122/9562 UUID version nibble (e.g. `4` or `7`).
  int((u.bytes[6] shr 4) and 0x0F'u8)

proc variant*(u: PgUuid): int {.inline, noSideEffect, tags: [].} =
  ## Returns the RFC variant nibble descriptor (2 = RFC 4122/9562 standard).
  let b = u.bytes[8]
  if (b and 0x80'u8) == 0'u8: 0
  elif (b and 0x40'u8) == 0'u8: 2
  elif (b and 0x20'u8) == 0'u8: 6
  else: 7

proc cmp*(a, b: PgUuid): int {.noSideEffect, tags: [].} =
  for i in 0 ..< 16:
    if a.bytes[i] < b.bytes[i]: return -1
    if a.bytes[i] > b.bytes[i]: return 1
  return 0

proc `==`*(a, b: PgUuid): bool {.inline, noSideEffect, tags: [].} =
  a.bytes == b.bytes

proc `<`*(a, b: PgUuid): bool {.inline, noSideEffect, tags: [].} =
  cmp(a, b) < 0

proc `<=`*(a, b: PgUuid): bool {.inline, noSideEffect, tags: [].} =
  cmp(a, b) <= 0

proc hash*(u: PgUuid): Hash {.noSideEffect, tags: [].} =
  var h: Hash = 0
  for b in u.bytes:
    h = h !& int(b)
  !$h

# Extraction & Return FFI for PostgreSQL Datum
proc getPgUuid*(datum: Datum): PgUuid {.noSideEffect, tags: [].} =
  ## Extracts a 16-byte `PgUuid` from a PostgreSQL `uuid` `Datum`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if datum == Datum(0):
        return nilUuid()
      discard pgx_datum_to_uuid_bytes(datum, addr result.bytes[0])

proc returnPgUuid*(u: PgUuid): Datum {.noSideEffect, tags: [].} =
  ## Allocates a `pg_uuid_t` in the active Postgres memory context and returns its `Datum`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      var tmp = u.bytes
      pgx_uuid_bytes_to_datum(addr tmp[0])
