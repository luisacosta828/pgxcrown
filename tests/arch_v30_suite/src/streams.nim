import pgxcrown
import std/options
import ./types

var streamsInitStep*: int32 = 0

proc initStreamsModule() {.pgxInit.} =
  streamsInitStep = 100

iterator v30_stream_range*(n: int64): int64 =
  var i: int64 = 1
  while i <= n:
    yield i
    inc i

iterator v30_stream_range*(startVal, endVal: int64): int64 =
  var i = startVal
  while i <= endVal:
    yield i
    inc i

iterator v30_stream_texts*(prefix: string, count: int32): Option[string] =
  for i in 1'i32 .. count:
    if (i mod 2'i32) == 0'i32:
      yield some(prefix & "-" & $i)
    else:
      yield none(string)

iterator v30_stream_items*(count: int32): ArchItem =
  for i in 1'i32 .. count:
    let st = if (i mod 2'i32) == 1'i32: asPending else: asActive
    yield ArchItem(id: i, label: "item-" & $i, status: st)

iterator v30_stream_error*(failAt: int32): int32 =
  for i in 1'i32 .. 100'i32:
    if i == failAt:
      raise newException(ValueError, "intentional stream abort at " & $i)
    yield i

proc v30_seq_items*(n: int32): seq[string] =
  result = @[]
  for i in 1'i32 .. n:
    result.add("seq-" & $i)
