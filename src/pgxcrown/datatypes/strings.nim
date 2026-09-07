## Zero-Copy String and Text Data Type for PostgreSQL in pgxcrown
##
## Maps PostgreSQL `text`, `varchar`, and `bpchar` (varlena) directly to a
## zero-copy slice without allocating memory or calling strlen.

import std/[options, hashes]
import ./basic

{.push header: "postgres.h".}
proc VARSIZE_ANY_EXHDR*(x: pointer): csize_t {.importc.}
proc VARDATA_ANY*(x: pointer): cstring {.importc.}
proc PG_DETOAST_DATUM_PACKED*(d: Datum): pointer {.importc.}
{.pop.}

{.push header: "utils/builtins.h".}
proc cstring_to_text_with_len*(s: pointer, len: cint): pointer {.importc.}
{.pop.}

type
  PgText* = object
    raw*: pointer
    dataPtr*: ptr UncheckedArray[char]
    len*: int

proc initPgText*(): PgText {.inline.} =
  PgText(raw: nil, dataPtr: nil, len: 0)

proc toPgText*(data: pointer, length: int): PgText {.inline.} =
  if length <= 0 or data == nil:
    return initPgText()
  PgText(raw: nil, dataPtr: cast[ptr UncheckedArray[char]](data), len: length)

proc toPgText*(s: string): PgText {.inline.} =
  if s.len == 0:
    return initPgText()
  PgText(raw: nil, dataPtr: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), len: s.len)

proc toPgText*(cs: cstring): PgText {.inline.} =
  if cs == nil:
    return initPgText()
  let clen = cs.len
  if clen == 0:
    return initPgText()
  PgText(raw: nil, dataPtr: cast[ptr UncheckedArray[char]](cs), len: clen)

template len*(t: PgText): int = t.len
template low*(t: PgText): int = 0
template high*(t: PgText): int = t.len - 1

proc `[]`*(t: PgText, idx: Natural): char {.inline.} =
  if idx >= t.len:
    raise newException(IndexDefect, "PgText index " & $idx & " out of bounds (len: " & $t.len & ")")
  t.dataPtr[idx]

proc `[]`*(t: PgText, slice: HSlice[int, int]): PgText =
  let a = max(0, slice.a)
  let b = min(t.len - 1, slice.b)
  if a > b or t.len == 0:
    return initPgText()
  let subLen = b - a + 1
  let subPtr = cast[ptr UncheckedArray[char]](cast[uint](t.dataPtr) + cast[uint](a))
  PgText(raw: t.raw, dataPtr: subPtr, len: subLen)

iterator items*(t: PgText): char =
  for i in 0 ..< t.len:
    yield t.dataPtr[i]

iterator pairs*(t: PgText): (int, char) =
  for i in 0 ..< t.len:
    yield (i, t.dataPtr[i])

template toOpenArray*(t: PgText, first, last: int): untyped =
  toOpenArray(t.dataPtr, first, last)

template toOpenArray*(t: PgText): untyped =
  toOpenArray(t.dataPtr, 0, t.len - 1)

converter toString*(t: PgText): string =
  if t.len == 0 or t.dataPtr == nil:
    return ""
  result = newString(t.len)
  copyMem(addr result[0], t.dataPtr, t.len)

proc `$`*(t: PgText): string {.inline.} =
  toString(t)

proc `==`*(a, b: PgText): bool =
  if a.len != b.len: return false
  if a.len == 0: return true
  if a.dataPtr == b.dataPtr: return true
  equalMem(a.dataPtr, b.dataPtr, a.len)

proc `!=`*(a, b: PgText): bool {.inline.} = not (a == b)

proc `==`*(a: PgText, b: string): bool =
  if a.len != b.len: return false
  if a.len == 0: return true
  equalMem(a.dataPtr, unsafeAddr b[0], a.len)

proc `!=`*(a: PgText, b: string): bool {.inline.} = not (a == b)

proc `==`*(a: string, b: PgText): bool {.inline.} = b == a

proc `!=`*(a: string, b: PgText): bool {.inline.} = not (a == b)

proc `==`*(a: PgText, b: cstring): bool =
  if b == nil: return a.len == 0
  let blen = b.len
  if a.len != blen: return false
  if a.len == 0: return true
  equalMem(a.dataPtr, cast[pointer](b), a.len)

proc `!=`*(a: PgText, b: cstring): bool {.inline.} = not (a == b)

proc `==`*(a: cstring, b: PgText): bool {.inline.} = b == a

proc `!=`*(a: cstring, b: PgText): bool {.inline.} = not (a == b)

proc `<`*(a, b: PgText): bool =
  let minLen = min(a.len, b.len)
  if minLen > 0:
    let cmp = cmpMem(a.dataPtr, b.dataPtr, minLen)
    if cmp != 0: return cmp < 0
  a.len < b.len

proc `<=`*(a, b: PgText): bool =
  (a == b) or (a < b)

proc startsWith*(t: PgText, prefix: string): bool =
  if prefix.len > t.len: return false
  if prefix.len == 0: return true
  equalMem(t.dataPtr, unsafeAddr prefix[0], prefix.len)

proc startsWith*(t: PgText, prefix: PgText): bool =
  if prefix.len > t.len: return false
  if prefix.len == 0: return true
  equalMem(t.dataPtr, prefix.dataPtr, prefix.len)

proc endsWith*(t: PgText, suffix: string): bool =
  if suffix.len > t.len: return false
  if suffix.len == 0: return true
  let offset = t.len - suffix.len
  let ptrAt = cast[pointer](cast[uint](t.dataPtr) + cast[uint](offset))
  equalMem(ptrAt, unsafeAddr suffix[0], suffix.len)

proc endsWith*(t: PgText, suffix: PgText): bool =
  if suffix.len > t.len: return false
  if suffix.len == 0: return true
  let offset = t.len - suffix.len
  let ptrAt = cast[pointer](cast[uint](t.dataPtr) + cast[uint](offset))
  equalMem(ptrAt, suffix.dataPtr, suffix.len)

proc find*(t: PgText, sub: char): int =
  for i in 0 ..< t.len:
    if t.dataPtr[i] == sub: return i
  return -1

proc find*(t: PgText, sub: string): int =
  if sub.len == 0: return 0
  if sub.len > t.len: return -1
  let maxIdx = t.len - sub.len
  for i in 0 .. maxIdx:
    let ptrAt = cast[pointer](cast[uint](t.dataPtr) + cast[uint](i))
    if equalMem(ptrAt, unsafeAddr sub[0], sub.len):
      return i
  return -1

proc find*(t: PgText, sub: PgText): int =
  if sub.len == 0: return 0
  if sub.len > t.len: return -1
  let maxIdx = t.len - sub.len
  for i in 0 .. maxIdx:
    let ptrAt = cast[pointer](cast[uint](t.dataPtr) + cast[uint](i))
    if equalMem(ptrAt, sub.dataPtr, sub.len):
      return i
  return -1

proc contains*(t: PgText, sub: char): bool {.inline.} =
  t.find(sub) >= 0

proc contains*(t: PgText, sub: string): bool {.inline.} =
  t.find(sub) >= 0

proc contains*(t: PgText, sub: PgText): bool {.inline.} =
  t.find(sub) >= 0

proc strip*(t: PgText): PgText =
  if t.len == 0: return t
  var a = 0
  var b = t.len - 1
  while a <= b and t.dataPtr[a] in {' ', '\t', '\n', '\r'}:
    inc a
  while b >= a and t.dataPtr[b] in {' ', '\t', '\n', '\r'}:
    dec b
  if a > b:
    return initPgText()
  let subLen = b - a + 1
  let subPtr = cast[ptr UncheckedArray[char]](cast[uint](t.dataPtr) + cast[uint](a))
  PgText(raw: t.raw, dataPtr: subPtr, len: subLen)

proc toLowerAscii*(t: PgText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    let c = t.dataPtr[i]
    result[i] = if c in 'A'..'Z': chr(ord(c) + 32) else: c

proc toUpperAscii*(t: PgText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    let c = t.dataPtr[i]
    result[i] = if c in 'a'..'z': chr(ord(c) - 32) else: c

proc `&`*(a: PgText, b: string): string {.inline.} = toString(a) & b
proc `&`*(a: string, b: PgText): string {.inline.} = a & toString(b)
proc `&`*(a, b: PgText): string {.inline.} = toString(a) & toString(b)
proc `&`*(a: PgText, b: char): string {.inline.} = toString(a) & b
proc `&`*(a: char, b: PgText): string {.inline.} = a & toString(b)

proc hash*(t: PgText): Hash =
  var h: Hash = 0
  for ch in t:
    h = h !& ord(ch)
  !$h

# Extraction from PostgreSQL Datum
proc getPgText*(datum: Datum): PgText =
  if datum == 0:
    return initPgText()
  let p = PG_DETOAST_DATUM_PACKED(datum)
  if p == nil:
    return initPgText()
  let length = VARSIZE_ANY_EXHDR(p).int
  let data = cast[ptr UncheckedArray[char]](VARDATA_ANY(p))
  PgText(raw: p, dataPtr: data, len: length)

# Return handlers to PostgreSQL Datum
proc returnPgText*(t: PgText): Datum =
  if t.len == 0:
    let res = cstring_to_text_with_len(nil, 0)
    return cast[Datum](res)
  let res = cstring_to_text_with_len(cast[pointer](t.dataPtr), cint(t.len))
  return cast[Datum](res)

proc returnPgText*(s: string): Datum =
  if s.len == 0:
    let res = cstring_to_text_with_len(nil, 0)
    return cast[Datum](res)
  let res = cstring_to_text_with_len(cast[pointer](unsafeAddr s[0]), cint(s.len))
  return cast[Datum](res)

proc returnPgText*(cs: cstring): Datum =
  if cs == nil or cs.len == 0:
    let res = cstring_to_text_with_len(nil, 0)
    return cast[Datum](res)
  let res = cstring_to_text_with_len(cast[pointer](cs), cint(cs.len))
  return cast[Datum](res)

proc returnPgText*[T](s: T): Datum {.inline.} =
  when compiles(string(s)):
    return returnPgText(string(s))
  elif compiles(cstring(s)):
    return returnPgText(cstring(s))
  elif compiles($s):
    return returnPgText($s)

