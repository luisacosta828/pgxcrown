import pgxcrown
import std/options
import ./types
import ./domain/overloads
import ./streams
import ./security_ops
include ./extra_inc

pgxExtension:
  version = "0.2.0"
  comment = "Milestone 2 multi-module architecture suite"
  relocatable = true
  trusted = true

var mainInitStep: int32 = 0

proc initMainModule() {.pgxInit.} =
  mainInitStep = 3

proc v30_init_sum*(): int32 =
  streamsInitStep + typesInitStep + domainInitStep + mainInitStep

proc v30_pair_sum*(a, b: int32): int32 {.immutable, parallelSafe.} =
  srcNoSqlAdd(a, b)

proc moduleRecurseStep(k: int32): int32 =
  var framePad {.volatile.}: array[128, byte]
  framePad[0] = byte(k and 0xff'i32)
  if k <= 0'i32:
    return 0'i32
  result = 1'i32 + moduleRecurseStep(k - 1'i32) + (int32(framePad[0]) and 0'i32)

proc v30_recurse_module*(n: int32): int32 =
  moduleRecurseStep(n)

proc v30_recurse_nested*(n: int32): int32 =
  proc innerStep(k: int32): int32 =
    var framePad {.volatile.}: array[128, byte]
    framePad[0] = byte(k and 0xff'i32)
    if k <= 0'i32:
      return 0'i32
    result = 1'i32 + innerStep(k - 1'i32) + (int32(framePad[0]) and 0'i32)
  result = innerStep(n)

# Inter-UDF DirectFunctionCall tests
proc v30_udf_helper*(x: int32): int32 {.immutable, parallelSafe.} =
  x + 1'i32

proc v30_udf_chain*(x: int32): int32 {.immutable, parallelSafe.} =
  v30_udf_helper(x) + v30_echo(x) + v30_echo(x, 10'i32) + v30_included_magic()

proc v30_udf_text_and_composite*(label: string, st: ArchStatus): string {.immutable, parallelSafe.} =
  v30_echo(label) & "|" &
    v30_describe(ArchItem(id: 7'i32, label: label, status: st)) & "|" &
    v30_describe(st)

proc v30_udf_opt_echo*(s: Option[string]): Option[string] {.immutable, parallelSafe.} =
  if s.isNone:
    return none(string)
  return some("opt:" & $s.get)

proc v30_udf_opt_chain*(s: Option[string]): Option[string] {.immutable, parallelSafe.} =
  v30_udf_opt_echo(s)

proc v30_udf_direct_recurse*(n: int32): int32 {.immutable, parallelSafe.} =
  var framePad {.volatile.}: array[128, byte]
  framePad[0] = byte(n and 0xff'i32)
  if n <= 0'i32:
    return 0'i32
  result = 1'i32 + v30_udf_direct_recurse(n - 1'i32) + (int32(framePad[0]) and 0'i32)

proc v30_udf_volatile_ping*(tag: string): string =
  v30_ping() & "|" & v30_ping(tag)
