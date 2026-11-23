import pgxcrown
import std/[options, strutils]

type
  Ex08OrderRow {.noSql.} = object
    id*: int32
    code*: string
    note*: Option[string]
    amount*: int64

  Ex08ItemRow {.noSql.} = object
    id*: int32
    sku*: string
    qty*: int32

var gSkuPlan: SpiPlan

proc ex08_insert_order*(code: string, note: Option[string], amount: int64): int32 {.volatile.} =
  ## Parameterized Binary SPI v2 INSERT ... RETURNING using QueryBuilder ($1, $2, $3).
  let t = table("ex08_orders")
  InsertInto(t, t.code, t.note, t.amount)
    .Values(code, note, amount)
    .Returning("id")
    .scalar(int32)

proc ex08_update_order_amount*(code: string, newAmount: int64): int64 {.volatile.} =
  ## Parameterized UPDATE ... WHERE ... RETURNING with QueryBuilder.
  let t = table("ex08_orders")
  Update(t)
    .Set(t.amount, newAmount)
    .Where(t.code == code)
    .Returning("amount")
    .scalar(int64)

proc ex08_inspect_orders*(minAmount: int64): string {.volatile.} =
  ## Binary deserialization with fetch[Ex08OrderRow], distinguishing SQL NULL vs "".
  let t = table("ex08_orders")
  let rows = fetch[Ex08OrderRow](
    Select(t.id, t.code, t.note, t.amount)
      .From(t)
      .Where(t.amount >= minAmount)
      .OrderBy(t.id.asc)
  )
  var parts: seq[string] = @[]
  for r in rows:
    let noteTag =
      if r.note.isNone: "NULL"
      elif r.note.get.len == 0: "EMPTY"
      else: "SOME(" & r.note.get & ")"
    parts.add($r.id & ":" & r.code & ":" & noteTag & ":" & $r.amount)
  parts.join("|")

proc ex08_prepare_sku_plan*(): bool {.volatile.} =
  ## Prepares and keeps a reusable SPI plan across backend calls (keep = true).
  if gSkuPlan.raw == nil:
    gSkuPlan = spiPrepare(
      "SELECT id, sku, qty FROM ex08_items WHERE sku = $1 ORDER BY id",
      [TEXTOID],
      keep = true
    )
  gSkuPlan.raw != nil and gSkuPlan.kept

proc ex08_lookup_sku*(sku: string): string {.volatile.} =
  ## Executes the kept prepared plan using binary bound parameter $1.
  if gSkuPlan.raw == nil:
    discard ex08_prepare_sku_plan()
  let rows = fetchPlan[Ex08ItemRow](gSkuPlan, [toBoundParam(sku)], readOnly = true)
  var parts: seq[string] = @[]
  for r in rows:
    parts.add($r.id & ":" & r.sku & ":" & $r.qty)
  parts.join("|")

proc ex08_stream_summary*(minQty: int32, batchSize: int32): string {.volatile.} =
  ## Combines explicit spiCursorOpen/Fetch/Close with QueryBuilder stream[Row] batching.
  var cur = spiCursorOpen(
    "ex08_cur",
    "SELECT id, sku, qty FROM ex08_items WHERE qty >= $1 ORDER BY id",
    [toBoundParam(minQty)]
  )
  var cursorRows = 0
  var cursorQtySum = 0'i64
  while true:
    let batch = spiCursorFetch[Ex08ItemRow](cur, int(batchSize))
    if batch.len == 0:
      break
    for item in batch:
      inc cursorRows
      cursorQtySum += int64(item.qty)
  spiCursorClose(cur)
  spiCursorClose(cur) # idempotent close

  let t = table("ex08_items")
  var qbRows = 0
  var qbQtySum = 0'i64
  for item in stream[Ex08ItemRow](
    Select(t.id, t.sku, t.qty).From(t).Where(t.qty >= minQty).OrderBy(t.id.asc),
    batchSize = int(batchSize)
  ):
    inc qbRows
    qbQtySum += int64(item.qty)

  "cursor_rows=" & $cursorRows & "|cursor_qty=" & $cursorQtySum &
    "|qb_rows=" & $qbRows & "|qb_qty=" & $qbQtySum
