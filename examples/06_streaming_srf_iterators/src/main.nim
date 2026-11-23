import pgxcrown
import std/options

type
  ex06_event_row* = object
    seq_no*: int32
    label*: string
    is_even*: bool

  StreamCleanupGuard {.noSql.} = object
    active: bool

var ex06Cleanups {.global.}: int32 = 0

proc `=destroy`(g: StreamCleanupGuard) =
  if g.active:
    inc ex06Cleanups

iterator ex06_stream_range*(n: int64): int64 {.immutable, parallelSafe.} =
  var i: int64 = 1
  while i <= n:
    yield i
    inc i

iterator ex06_stream_range*(startVal, endVal: int64): int64 {.immutable, parallelSafe.} =
  var i = startVal
  while i <= endVal:
    yield i
    inc i

iterator ex06_stream_nullable*(prefix: string, count: int32): Option[string] {.immutable, parallelSafe.} =
  for i in 1'i32 .. count:
    if (i mod 2'i32) == 0'i32:
      yield some(prefix & "-" & $i)
    else:
      yield none(string)

iterator ex06_stream_events*(count: int32): ex06_event_row {.immutable, parallelSafe.} =
  for i in 1'i32 .. count:
    yield ex06_event_row(
      seq_no: i,
      label: "event-" & $i,
      is_even: (i mod 2'i32) == 0'i32
    )

iterator ex06_stream_guarded*(total: int32, failAt: int32 = 0): int32 =
  var guard = StreamCleanupGuard(active: true)
  for i in 1'i32 .. total:
    if failAt > 0'i32 and i == failAt:
      raise newException(ValueError, "intentional stream abort at row " & $i)
    yield i
  guard.active = false
  inc ex06Cleanups

proc ex06_cleanup_count*(): int32 {.volatile.} =
  ex06Cleanups
