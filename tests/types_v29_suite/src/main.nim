import pgxcrown
import std/[options, strutils, times]

# =============================================================================
# E2E Regression Suite: Milestone 1 (v0.29.0) Production Data Types & FFI
# Covers: PgBytea, PgUuid, PgDate, PgTimestamp, PgTimestampTz, PgInterval,
#         PgNumeric, complete enums (default & {.pure.} string labels),
#         plain & {.pgxType.} distinct types, composites, arrays, SRFs, and SPI.
# =============================================================================

type
  TicketPriority* = enum
    tpLow
    tpMedium
    tpHigh

  PaymentState* {.pure.} = enum
    psPending = "pending"
    psPaid = "paid"
    psRefunded = "refunded"

  AccountId* = distinct int64
  MerchantCode* = distinct string
  ActiveFlag* = distinct bool
  GradeChar* = distinct char
  BigCounter* = distinct uint64

  slug* {.pgxType: string.} = distinct string

  InvoiceSummary* = object
    id*: AccountId
    tx_uuid*: PgUuid
    issued_on*: PgDate
    settled_at*: Option[PgTimestampTz]
    zero_count*: Option[int32]
    amount*: PgNumeric
    state*: PaymentState
    signature*: PgBytea

  BatchTagBundle* = object
    codes*: seq[int]
    priorities*: seq[TicketPriority]

  SpiInvoiceRow* {.noSql.} = object
    id*: PgUuid
    ledger*: AccountId
    payload*: PgBytea
    issued_on*: PgDate
    settled_at*: Option[PgTimestampTz]
    grace*: PgInterval
    amount*: PgNumeric
    status*: PaymentState

# -----------------------------------------------------------------------------
# 0. Custom SQL Base Type ({.pgxType: string.})
# -----------------------------------------------------------------------------
proc parse_slug*(s: cstring): slug {.pgxInput, immutable, parallelSafe.} =
  ($s).strip().toLowerAscii().replace(" ", "-").slug

proc format_slug*(val: slug): string {.pgxOutput, immutable, parallelSafe.} =
  result = val.string

# -----------------------------------------------------------------------------
# 1. PgBytea (Zero-Copy NUL-Safe Binary Buffer)
# -----------------------------------------------------------------------------
proc bytea_roundtrip_xor*(b: PgBytea): PgBytea {.immutable, parallelSafe.} =
  var outBytes = newSeq[byte](b.len)
  for i in 0 ..< b.len:
    outBytes[i] = b[i] xor 0xFF'u8
  return toPgBytea(outBytes)

proc bytea_nul_stats*(b: PgBytea): string {.immutable, parallelSafe.} =
  var nulCount = 0
  for item in b:
    if item == 0x00'u8:
      inc nulCount
  return "len=" & $b.len & ",nuls=" & $nulCount & ",hex=" & $b

proc bytea_opt_echo*(b: Option[PgBytea]): Option[PgBytea] {.immutable, parallelSafe.} =
  return b

proc bytea_array_total_len*(items: seq[PgBytea]): int32 {.immutable, parallelSafe.} =
  var total = 0
  for item in items:
    total += item.len
  return total.int32

proc bytea_srf_pair*(a: PgBytea, b: PgBytea): seq[PgBytea] {.immutable, parallelSafe.} =
  return @[a, b]

# -----------------------------------------------------------------------------
# 2. PgUuid (Native 16-byte UUID)
# -----------------------------------------------------------------------------
proc uuid_version_info*(u: PgUuid): string {.immutable, parallelSafe.} =
  return "ver=" & $u.version() & ",var=" & $u.variant() & ",str=" & $u

proc uuid_from_text_safe*(s: string): PgUuid {.immutable, parallelSafe.} =
  return parsePgUuid(s)

proc uuid_opt_or_nil*(u: Option[PgUuid]): Option[PgUuid] {.immutable, parallelSafe.} =
  if u.isNone:
    return none(PgUuid)
  return some(u.get)

proc uuid_array_join*(ids: seq[PgUuid]): string {.immutable, parallelSafe.} =
  var parts: seq[string] = @[]
  for id in ids:
    parts.add($id)
  return parts.join(",")

proc uuid_srf_list*(): seq[PgUuid] {.immutable, parallelSafe.} =
  return @[
    nilUuid(),
    parsePgUuid("018f4230-1a2b-7c3d-8000-112233445566")
  ]

# -----------------------------------------------------------------------------
# 3. Temporal Types (PgDate, PgTimestamp, PgTimestampTz, PgInterval + std/times)
# -----------------------------------------------------------------------------
proc date_roundtrip_and_shift*(d: PgDate, delta: int32): PgDate {.immutable, parallelSafe.} =
  return d + delta

proc date_via_datetime_utc*(d: PgDate): string {.immutable, parallelSafe.} =
  if not d.isFinite():
    return "inf:" & $d
  let dt = d.toDateTimeUtc()
  return "days=" & $d.days & ",ymd=" & $dt.toPgDate()

proc timestamptz_via_std_times*(ts: PgTimestampTz): PgTimestampTz {.immutable, parallelSafe.} =
  if not ts.isFinite():
    return ts
  return ts.toTime().toPgTimestampTz()

proc timestamp_add_seconds*(ts: PgTimestamp, secs: int64): PgTimestamp {.immutable, parallelSafe.} =
  return ts.addUsecs(secs * UsecsPerSec)

proc interval_add_and_duration*(iv: PgInterval, extraUs: int64): PgInterval {.immutable, parallelSafe.} =
  if iv.months == 0:
    let dur = iv.toDuration() + initDuration(microseconds = extraUs)
    return dur.toPgInterval()
  return iv + initPgInterval(microseconds = extraUs)

proc temporal_array_summary*(ds: seq[PgDate], tzs: seq[PgTimestampTz], ivs: seq[PgInterval]): string {.immutable, parallelSafe.} =
  var parts: seq[string] = @[]
  parts.add("dates=" & $ds.len & (if ds.len > 0: "(" & $ds[0] & ")" else: ""))
  parts.add("tzs=" & $tzs.len & (if tzs.len > 0: "(" & $tzs[0] & ")" else: ""))
  parts.add("ivs=" & $ivs.len & (if ivs.len > 0: "(" & $ivs[0] & ")" else: ""))
  return parts.join(";")

# -----------------------------------------------------------------------------
# 4. PgNumeric (Arbitrary-Precision Decimal via PG Kernel)
# -----------------------------------------------------------------------------
proc numeric_exact_add*(a: PgNumeric, b: PgNumeric): PgNumeric {.immutable, parallelSafe.} =
  return a + b

proc numeric_exact_calc*(price: PgNumeric, qty: PgNumeric, taxRate: PgNumeric): PgNumeric {.immutable, parallelSafe.} =
  let factor = pgNumeric("1") + taxRate
  return (price * qty * factor).round(2)

proc numeric_trunc_val*(x: PgNumeric, scale: int32): PgNumeric {.immutable, parallelSafe.} =
  return x.trunc(scale)

proc numeric_safe_div*(a: PgNumeric, b: PgNumeric): PgNumeric {.immutable, parallelSafe.} =
  return a / b

proc numeric_sum_array*(vals: seq[PgNumeric]): PgNumeric {.immutable, parallelSafe.} =
  var total = initPgNumericZero()
  for v in vals:
    total = total + v
  return total

proc numeric_srf_series*(startVal: PgNumeric, stepVal: PgNumeric, count: int32): seq[PgNumeric] {.immutable, parallelSafe.} =
  result = @[]
  var cur = startVal
  for i in 0 ..< count:
    result.add(cur)
    cur = cur + stepVal

# -----------------------------------------------------------------------------
# 5. Complete Enum & Distinct FFI Support
# -----------------------------------------------------------------------------
proc classify_ticket*(p: TicketPriority = tpMedium): string {.immutable, parallelSafe.} =
  case p
  of tpLow, tpMedium:
    return "standard:" & $p
  of tpHigh:
    return "urgent:" & $p

proc nextPaymentState(st: PaymentState): PaymentState {.noSideEffect.} =
  case st
  of PaymentState.psPending: return PaymentState.psPaid
  of PaymentState.psPaid: return PaymentState.psRefunded
  of PaymentState.psRefunded: return PaymentState.psRefunded

proc advance_payment_state*(st: PaymentState): PaymentState {.immutable, parallelSafe.} =
  return nextPaymentState(st)

proc opt_payment_state*(st: Option[PaymentState]): Option[PaymentState] {.immutable, parallelSafe.} =
  if st.isNone:
    return none(PaymentState)
  return some(nextPaymentState(st.get))

proc priority_array_count*(items: seq[TicketPriority]): int32 {.immutable, parallelSafe.} =
  var highs: int32 = 0
  for item in items:
    if item == tpHigh:
      highs += 1
  return highs

proc list_priorities*(): seq[TicketPriority] {.immutable, parallelSafe.} =
  return @[tpLow, tpMedium, tpHigh]

proc distinct_account_next*(id: AccountId): AccountId {.immutable, parallelSafe.} =
  return AccountId(int64(id) + 1'i64)

proc distinct_merchant_upper*(c: MerchantCode): MerchantCode {.immutable, parallelSafe.} =
  return MerchantCode(string(c).toUpperAscii())

proc distinct_flag_invert*(f: ActiveFlag): ActiveFlag {.immutable, parallelSafe.} =
  return ActiveFlag(not bool(f))

proc distinct_grade_shift*(g: GradeChar): GradeChar {.immutable, parallelSafe.} =
  return GradeChar(chr(ord(char(g)) + 1))

proc distinct_big_counter*(c: BigCounter): BigCounter {.immutable, parallelSafe.} =
  return BigCounter(uint64(c) + 100'u64)

proc distinct_merchant_opt*(c: Option[MerchantCode]): Option[MerchantCode] {.immutable, parallelSafe.} =
  if c.isNone:
    return none(MerchantCode)
  return some(MerchantCode("M-" & string(c.get).toUpperAscii()))

proc distinct_account_srf*(baseId: AccountId): seq[AccountId] {.immutable, parallelSafe.} =
  let b = int64(baseId)
  return @[AccountId(b), AccountId(b + 1'i64), AccountId(b + 2'i64)]

# -----------------------------------------------------------------------------
# 6. Composite Object & SPI Round-Trip
# -----------------------------------------------------------------------------
proc build_invoice_summary*(
  id: AccountId,
  txUuid: PgUuid,
  issuedOn: PgDate,
  settledAt: Option[PgTimestampTz],
  zeroCount: Option[int32],
  amount: PgNumeric,
  state: PaymentState,
  sig: PgBytea
): InvoiceSummary {.immutable, parallelSafe.} =
  return InvoiceSummary(
    id: id,
    tx_uuid: txUuid,
    issued_on: issuedOn,
    settled_at: settledAt,
    zero_count: zeroCount,
    amount: amount,
    state: state,
    signature: sig
  )

proc describe_invoice_summary*(inv: InvoiceSummary): string {.immutable, parallelSafe.} =
  let zStr = if inv.zero_count.isSome: "some(" & $inv.zero_count.get & ")" else: "none"
  let sStr = if inv.settled_at.isSome: $inv.settled_at.get else: "none"
  return "id=" & $int64(inv.id) &
         "|uuid=" & $inv.tx_uuid &
         "|date=" & $inv.issued_on &
         "|settled=" & sStr &
         "|zero=" & zStr &
         "|amt=" & $inv.amount &
         "|state=" & $inv.state &
         "|sig=" & $inv.signature &
         "(len=" & $inv.signature.len & ")"

proc spi_v29_roundtrip*(): string {.volatile.} =
  discard spiCreateTableFrom[SpiInvoiceRow]("v29_invoices", ifNotExists = true, primaryKey = "id")
  let uid1 = parsePgUuid("550e8400-e29b-41d4-a716-446655440000")
  let bin1 = toPgBytea(@[0x00'u8, 0xaa'u8, 0x00'u8, 0x55'u8])
  let d1 = initPgDate(2000, 1, 1)
  let ts1 = initPgTimestampTz(2024, 2, 29, 18, 45, 30, 250_000)
  let iv1 = initPgInterval(months = 1, days = 2, hours = 3, minutes = 4, seconds = 5)
  let amt1 = pgNumeric("987654321098765432109876543210.1234")

  let rowObj = SpiInvoiceRow(
    id: uid1,
    ledger: AccountId(42'i64),
    payload: bin1,
    issued_on: d1,
    settled_at: some(ts1),
    grace: iv1,
    amount: amt1,
    status: PaymentState.psPaid
  )
  discard spiInsertFrom(rowObj, tableName = "v29_invoices")

  let t = table("v29_invoices", "i")
  doAssert ($Update(t).Set(t.ledger, toPgText("42")).Where(t.id == uid1)).contains("42")
  let fetched = Select(t.id, t.ledger, t.payload, t.issued_on, t.settled_at, t.grace, t.amount, t.status)
    .From(t)
    .Where(t.id == uid1)
    .all(SpiInvoiceRow)

  if fetched.len == 0:
    return "empty"
  let r = fetched[0]
  return "id=" & $r.id &
         "|ledger=" & $int64(r.ledger) &
         "|payload=" & $r.payload &
         "|date=" & $r.issued_on &
         "|settled=" & (if r.settled_at.isSome: $r.settled_at.get else: "none") &
         "|grace=" & $r.grace &
         "|amount=" & $r.amount &
         "|status=" & $r.status

proc roundtrip_batch_bundle*(b: BatchTagBundle): BatchTagBundle {.immutable, parallelSafe.} =
  return b

proc describe_batch_bundle*(b: BatchTagBundle): string {.immutable, parallelSafe.} =
  var codeStrs: seq[string] = @[]
  for c in b.codes:
    codeStrs.add($c)
  var prioStrs: seq[string] = @[]
  for p in b.priorities:
    prioStrs.add($p)
  return "codes=" & codeStrs.join(",") & "|prios=" & prioStrs.join(",")

proc empty_uuid_srf*(): seq[PgUuid] {.immutable, parallelSafe.} =
  @[]
