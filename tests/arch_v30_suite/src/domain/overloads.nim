import pgxcrown
import ../types
import ../../private/secret_math

var domainInitStep*: int32 = 0

proc initDomainModule() {.pgxInit.} =
  domainInitStep = 7

proc v30_echo*(x: int32): int32 {.immutable, parallelSafe.} =
  x

proc v30_echo*(x: int64): int64 {.immutable, parallelSafe.} =
  x + 10000000000'i64

proc v30_echo*(x: float64): float64 {.immutable, parallelSafe.} =
  x * 2.0

proc v30_echo*(x: string): string {.immutable, parallelSafe.} =
  "text:" & x

proc v30_echo*(a, b: int32): int32 {.immutable, parallelSafe.} =
  a + b

proc v30_describe*(item: ArchItem): string {.immutable, parallelSafe.} =
  $item.id & ":" & item.label & ":" & $item.status

proc v30_describe*(st: ArchStatus): string {.immutable, parallelSafe.} =
  "status=" & $st

proc v30_ping*(): string =
  "pong"

proc v30_ping*(tag: string): string =
  "pong:" & tag

proc v30_scaled*(x, factor: int32): int32 {.immutable, parallelSafe.} =
  secretScale(x, factor)
