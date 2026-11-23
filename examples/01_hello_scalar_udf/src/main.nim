import pgxcrown
import std/strutils

var ex01SeqCounter {.global.}: int32 = 0

proc ex01_greet*(target: string): string {.immutable, parallelSafe.} =
  "Hello, " & target & " from pgxcrown!"

proc ex01_add*(a, b: int32): int32 {.immutable, parallelSafe.} =
  a + b

proc ex01_slugify*(raw: string): string {.immutable, parallelSafe.} =
  var parts: seq[string] = @[]
  for token in raw.strip().toLowerAscii().splitWhitespace():
    if token.len > 0:
      parts.add(token)
  parts.join("-")

proc ex01_discount*(amount: float64, pct: float64): float64 {.stable.} =
  amount * (1.0 - pct / 100.0)

proc ex01_next_seq*(): int32 {.volatile.} =
  inc ex01SeqCounter
  ex01SeqCounter
