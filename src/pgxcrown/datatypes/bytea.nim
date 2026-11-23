## Zero-Copy NUL-Safe Binary Buffer Data Type (`bytea`) for PostgreSQL in pgxcrown
##
## Maps PostgreSQL `bytea` directly to a length-prefixed binary view without
## allocating or truncating at embedded NUL (0x00) bytes.

import std/[hashes, json, os]
import ./basic

const PgxCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxCHeadersDir).}

{.push header: "pgx_types.h".}
proc pgx_detoast_bytea(d: Datum): pointer {.importc.}
proc pgx_bytea_len(p: pointer): csize_t {.importc.}
proc pgx_bytea_data(p: pointer): pointer {.importc.}
proc pgx_alloc_bytea(src: pointer, len: csize_t): Datum {.importc.}
{.pop.}

type
  PgBytea* = object
    ## Binary PostgreSQL `bytea` value or zero-copy detoasted view.
    ## Embedded NUL (`0x00`) bytes are preserved in full.
    raw*: pointer
    dataPtr*: ptr UncheckedArray[byte]
    len*: int
    owned*: seq[byte]

template rawBytePtr*(b: PgBytea): ptr UncheckedArray[byte] =
  (if b.owned.len > 0: cast[ptr UncheckedArray[byte]](unsafeAddr b.owned[0]) else: b.dataPtr)

proc activePtr(b: PgBytea): ptr UncheckedArray[byte] {.inline, noSideEffect, tags: [].} =
  if b.owned.len > 0:
    cast[ptr UncheckedArray[byte]](unsafeAddr b.owned[0])
  else:
    b.dataPtr

proc initPgBytea*(): PgBytea {.inline, noSideEffect, tags: [].} =
  ## Initializes an empty `PgBytea`.
  PgBytea(raw: nil, dataPtr: nil, len: 0, owned: @[])

proc initPgByteaView*(data: pointer, length: int): PgBytea {.inline, noSideEffect, tags: [].} =
  ## Wraps an existing buffer as a zero-copy borrowed `PgBytea` view.
  if length <= 0 or data == nil:
    return initPgBytea()
  PgBytea(raw: nil, dataPtr: cast[ptr UncheckedArray[byte]](data), len: length, owned: @[])

proc toPgBytea*(bytes: openArray[byte]): PgBytea {.noSideEffect, tags: [].} =
  ## Copies an `openArray[byte]` into an owned, NUL-safe `PgBytea`.
  if bytes.len == 0:
    return initPgBytea()
  var buf = newSeq[byte](bytes.len)
  copyMem(addr buf[0], unsafeAddr bytes[0], bytes.len)
  PgBytea(raw: nil, dataPtr: nil, len: bytes.len, owned: move(buf))

proc toPgBytea*(s: string): PgBytea {.noSideEffect, tags: [].} =
  ## Copies raw bytes from a Nim `string` (including embedded `\0` bytes) into an owned `PgBytea`.
  if s.len == 0:
    return initPgBytea()
  var buf = newSeq[byte](s.len)
  copyMem(addr buf[0], unsafeAddr s[0], s.len)
  PgBytea(raw: nil, dataPtr: nil, len: s.len, owned: move(buf))

proc hexNibble(ch: char): int {.inline, noSideEffect, raises: [ValueError], tags: [].} =
  case ch
  of '0'..'9': ord(ch) - ord('0')
  of 'a'..'f': ord(ch) - ord('a') + 10
  of 'A'..'F': ord(ch) - ord('A') + 10
  else:
    raise newException(ValueError, "Invalid hexadecimal character in bytea literal: '" & ch & "'")

proc fromHexBytea*(hexStr: openArray[char]): PgBytea {.noSideEffect, raises: [ValueError], tags: [].} =
  ## Parses a PostgreSQL hex-encoded bytea literal (`\x...` or plain hex) into `PgBytea`.
  var startIdx = 0
  if hexStr.len >= 2 and hexStr[0] == '\\' and (hexStr[1] == 'x' or hexStr[1] == 'X'):
    startIdx = 2
  elif hexStr.len >= 3 and hexStr[0] == '\\' and hexStr[1] == '\\' and (hexStr[2] == 'x' or hexStr[2] == 'X'):
    startIdx = 3
  let digitCount = hexStr.len - startIdx
  if digitCount == 0:
    return initPgBytea()
  if (digitCount and 1) != 0:
    raise newException(ValueError, "Hex bytea string must have an even number of digits")
  let byteLen = digitCount shr 1
  var buf = newSeq[byte](byteLen)
  for i in 0 ..< byteLen:
    let hi = hexNibble(hexStr[startIdx + i * 2])
    let lo = hexNibble(hexStr[startIdx + i * 2 + 1])
    buf[i] = byte((hi shl 4) or lo)
  PgBytea(raw: nil, dataPtr: nil, len: byteLen, owned: move(buf))

template len*(b: PgBytea): int = b.len
template low*(b: PgBytea): int = 0
template high*(b: PgBytea): int = b.len - 1
proc isEmpty*(b: PgBytea): bool {.inline, noSideEffect, tags: [].} = b.len == 0

proc `[]`*(b: PgBytea, idx: Natural): byte {.inline, noSideEffect, tags: [].} =
  if idx >= b.len:
    raise newException(IndexDefect, "PgBytea index " & $idx & " out of bounds (len: " & $b.len & ")")
  let p = b.activePtr()
  p[idx]

proc `[]`*(b: PgBytea, slice: HSlice[int, int]): PgBytea {.noSideEffect, tags: [].} =
  ## Returns a sub-slice of `b` (zero-copy when backed by detoasted Postgres memory).
  let a = max(0, slice.a)
  let c = min(b.len - 1, slice.b)
  if a > c or b.len == 0:
    return initPgBytea()
  let subLen = c - a + 1
  if b.owned.len > 0:
    return toPgBytea(b.owned.toOpenArray(a, c))
  let subPtr = cast[ptr UncheckedArray[byte]](cast[uint](b.dataPtr) + cast[uint](a))
  PgBytea(raw: b.raw, dataPtr: subPtr, len: subLen, owned: @[])

iterator items*(b: PgBytea): byte =
  let p = b.activePtr()
  for i in 0 ..< b.len:
    yield p[i]

iterator pairs*(b: PgBytea): (int, byte) =
  let p = b.activePtr()
  for i in 0 ..< b.len:
    yield (i, p[i])

template toOpenArray*(b: PgBytea, first, last: int): untyped =
  toOpenArray(rawBytePtr(b), first, last)

template toOpenArray*(b: PgBytea): untyped =
  toOpenArray(rawBytePtr(b), 0, b.len - 1)

proc toBytes*(b: PgBytea): seq[byte] {.noSideEffect, tags: [].} =
  ## Materializes all bytes into a new `seq[byte]`, preserving embedded NULs.
  if b.len == 0:
    return @[]
  result = newSeq[byte](b.len)
  copyMem(addr result[0], b.activePtr(), b.len)

proc toRawString*(b: PgBytea): string {.noSideEffect, tags: [].} =
  ## Copies all bytes into a Nim `string` (note: NUL bytes are preserved in Nim strings).
  if b.len == 0:
    return ""
  result = newString(b.len)
  copyMem(addr result[0], b.activePtr(), b.len)

const HexDigitsLower = "0123456789abcdef"

proc toHexBytea*(b: PgBytea, prefix: bool = true): string {.noSideEffect, tags: [].} =
  ## Formats `PgBytea` in PostgreSQL hex format (`\x...`) or raw lowercase hex.
  let offset = if prefix: 2 else: 0
  result = newString(offset + b.len * 2)
  if prefix:
    result[0] = '\\'
    result[1] = 'x'
  let p = b.activePtr()
  for i in 0 ..< b.len:
    let val = int(p[i])
    result[offset + i * 2] = HexDigitsLower[(val shr 4) and 0xF]
    result[offset + i * 2 + 1] = HexDigitsLower[val and 0xF]

proc `$`*(b: PgBytea): string {.inline, noSideEffect, tags: [].} =
  toHexBytea(b, prefix = true)

proc `%`*(b: PgBytea): JsonNode {.inline, noSideEffect, tags: [].} =
  {.cast(tags: []).}:
    newJString(toHexBytea(b, prefix = true))

proc `==`*(a, b: PgBytea): bool {.noSideEffect, tags: [].} =
  if a.len != b.len: return false
  if a.len == 0: return true
  let pa = a.activePtr()
  let pb = b.activePtr()
  if pa == pb: return true
  equalMem(pa, pb, a.len)

proc `==`*(a: PgBytea, b: openArray[byte]): bool {.noSideEffect, tags: [].} =
  if a.len != b.len: return false
  if a.len == 0: return true
  equalMem(a.activePtr(), unsafeAddr b[0], a.len)

proc `==`*(a: openArray[byte], b: PgBytea): bool {.inline, noSideEffect, tags: [].} =
  b == a

proc `<`*(a, b: PgBytea): bool {.noSideEffect, tags: [].} =
  let minLen = min(a.len, b.len)
  if minLen > 0:
    let cmp = cmpMem(a.activePtr(), b.activePtr(), minLen)
    if cmp != 0: return cmp < 0
  a.len < b.len

proc `<=`*(a, b: PgBytea): bool {.inline, noSideEffect, tags: [].} =
  (a == b) or (a < b)

proc hash*(b: PgBytea): Hash {.noSideEffect, tags: [].} =
  var h: Hash = 0
  let p = b.activePtr()
  for i in 0 ..< b.len:
    h = h !& int(p[i])
  !$h

# Extraction & Return FFI for PostgreSQL Datum
proc getPgBytea*(datum: Datum): PgBytea {.noSideEffect, tags: [].} =
  ## Extracts a zero-copy `PgBytea` view from a PostgreSQL `bytea` `Datum`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if datum == Datum(0):
        return initPgBytea()
      let p = pgx_detoast_bytea(datum)
      if p == nil:
        return initPgBytea()
      let length = int(pgx_bytea_len(p))
      if length <= 0:
        return PgBytea(raw: p, dataPtr: nil, len: 0, owned: @[])
      let data = cast[ptr UncheckedArray[byte]](pgx_bytea_data(p))
      PgBytea(raw: p, dataPtr: data, len: length, owned: @[])

proc returnPgBytea*(b: PgBytea): Datum {.noSideEffect, tags: [].} =
  ## Serializes a `PgBytea` (preserving embedded NUL bytes) to a PostgreSQL `bytea` `Datum`.
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if b.len == 0:
        return pgx_alloc_bytea(nil, 0)
      pgx_alloc_bytea(cast[pointer](b.activePtr()), csize_t(b.len))

proc returnPgBytea*(bytes: openArray[byte]): Datum {.inline, noSideEffect, tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if bytes.len == 0:
        return pgx_alloc_bytea(nil, 0)
      pgx_alloc_bytea(unsafeAddr bytes[0], csize_t(bytes.len))
