import pgxcrown
import std/strutils

type
  ex03_order_state* {.pure.} = enum
    osPending = "pending"
    osConfirmed = "confirmed"
    osShipped = "shipped"

  ex03_line_item* = object
    sku*: string
    qty*: int32
    unit_cents*: int32
    state*: ex03_order_state

proc ex03_next_state*(st: ex03_order_state = ex03_order_state.osPending): ex03_order_state {.immutable, parallelSafe.} =
  case st
  of ex03_order_state.osPending:
    ex03_order_state.osConfirmed
  of ex03_order_state.osConfirmed, ex03_order_state.osShipped:
    ex03_order_state.osShipped

proc ex03_make_item*(
  sku: string,
  qty: int32,
  unitCents: int32,
  st: ex03_order_state = ex03_order_state.osPending
): ex03_line_item {.immutable, parallelSafe.} =
  ex03_line_item(
    sku: sku.strip().toUpperAscii(),
    qty: qty,
    unit_cents: unitCents,
    state: st
  )

proc ex03_item_total_cents*(item: ex03_line_item): int64 {.immutable, parallelSafe.} =
  int64(item.qty) * int64(item.unit_cents)

proc ex03_sum_order_cents*(items: seq[ex03_line_item]): int64 {.immutable, parallelSafe.} =
  var total: int64 = 0
  for item in items:
    total += int64(item.qty) * int64(item.unit_cents)
  total

proc ex03_build_order*(
  skus: seq[string],
  qtys: seq[int32],
  unitCents: int32
): seq[ex03_line_item] {.immutable, parallelSafe.} =
  if skus.len != qtys.len:
    raise newException(ValueError, "skus and qtys arrays must have the same length")
  result = newSeq[ex03_line_item](skus.len)
  for i in 0 ..< skus.len:
    let st = if qtys[i] > 0'i32: ex03_order_state.osConfirmed else: ex03_order_state.osPending
    result[i] = ex03_line_item(
      sku: skus[i].strip().toUpperAscii(),
      qty: qtys[i],
      unit_cents: unitCents,
      state: st
    )

proc ex03_sum_i32*(nums: seq[int32]): int64 {.immutable, parallelSafe.} =
  var total: int64 = 0
  for n in nums:
    total += int64(n)
  total

proc ex03_join_tags*(tags: seq[string], sep: string = ", "): string {.immutable, parallelSafe.} =
  tags.join(sep)

proc ex03_scale_vector*(vec: PgVector[int32], factor: int32): PgVector[int32] {.immutable, parallelSafe.} =
  var outSeq = newSeq[int32](vec.len)
  for i in 0 ..< vec.len:
    outSeq[i] = vec[i] * factor
  toPgVector(outSeq)
