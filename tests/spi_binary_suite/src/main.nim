import pgxcrown
import std/[options, json, math, strutils, typetraits]

pgxExtension:
  version = "0.1.0"
  comment = "SPI Binary v2 end-to-end test suite"
  relocatable = true
  trusted = false

type
  PluginBadge = object
    tag: string

  HookRow = object
    id: int32
    badge: PluginBadge
    opt_badge: Option[PluginBadge]

  OptTextRow = object
    id: int32
    txt: Option[string]
    note: Option[string]

  RetRow = object
    id: int32
    txt: string
    qty: int32

  SbColor = enum
    scRed = "red"
    scGreen = "green"
    scBlue = "blue"

  SbAccountId = distinct int64
  SbCode = distinct string

  FullBinaryRow = object
    id: SbAccountId
    code: SbCode
    i16: int16
    i32: int32
    i64: int64
    oid_col: uint32
    f32: float32
    f64: float64
    f_nan: float64
    f_inf: float64
    flag: bool
    txt: PgText
    vchar: string
    doc: JsonNode
    raw_json: JsonNode
    payload: PgBytea
    uid: PgUuid
    dt: PgDate
    ts: PgTimestamp
    tstz: PgTimestampTz
    iv: PgInterval
    num: PgNumeric
    color_enum: SbColor
    color_text: SbColor
    iarr: seq[int32]
    i8arr: seq[int64]
    farr: seq[float64]
    barr: seq[bool]
    sarr: seq[Option[string]]

  FullInsertItem = object
    label: string
    score: int64
    active: bool

  StreamRow = object
    id: int32
    grp: int32
    val: int64

  PlanRow = object
    id: int32
    name: string
    qty: int32

  TxRow = object
    id: int32
    tag: string

proc pgxFromDatum(d: Datum, _: typedesc[PluginBadge]): PluginBadge =
  let raw = datumToNim[string](d, TEXTOID, false)
  PluginBadge(tag: "ext:" & raw)

var gKeptPlan: SpiPlan

proc sb_init_kept_plan*(): bool =
  if gKeptPlan.raw == nil:
    gKeptPlan = spiPrepare(
      "SELECT id, tag AS name, qty FROM sb_kept_items WHERE tag = $1 ORDER BY id",
      [TEXTOID],
      keep = true
    )
  result = (gKeptPlan.raw != nil and gKeptPlan.kept)

proc sb_kept_plan_fetch*(tag: string): string =
  if gKeptPlan.raw == nil:
    discard sb_init_kept_plan()
  let rows = fetchPlan[PlanRow](gKeptPlan, [toBoundParam(tag)], readOnly = true)
  var parts: seq[string] = @[]
  for r in rows:
    parts.add($r.id & ":" & r.name & ":" & $r.qty)
  result = parts.join("|")

proc dropTempIfExists(name: string) =
  discard fetchRawRows(
    "DO $$ BEGIN IF to_regclass('pg_temp." & name & "') IS NOT NULL THEN DROP TABLE pg_temp." & name & "; END IF; END $$"
  )

proc sb_null_vs_empty*(): string =
  dropTempIfExists("sb_null_tbl")
  discard fetchRawRows("""
    CREATE TEMP TABLE sb_null_tbl (
      id serial PRIMARY KEY,
      txt text,
      dropped_mid text,
      note text
    )
  """)
  discard fetchRawRows("ALTER TABLE pg_temp.sb_null_tbl DROP COLUMN dropped_mid")

  let tbl = table("sb_null_tbl")
  discard InsertInto(tbl, "txt", "note")
    .Values("", some("empty-str"))
    .Values(none(string), none(string))
    .Values("hello", some("$1; DROP TABLE sb_null_tbl; --"))
    .run()

  let typed = Select(tbl.id, tbl.txt, tbl.note).From(tbl).OrderBy(tbl.id.asc).fetch(OptTextRow)
  doAssert typed.len == 3
  doAssert typed[0].txt.isSome and typed[0].txt.get == ""
  doAssert typed[0].note == some("empty-str")
  doAssert typed[1].txt.isNone
  doAssert typed[1].note.isNone
  doAssert typed[2].txt == some("hello")
  doAssert typed[2].note == some("$1; DROP TABLE sb_null_tbl; --")

  # Legacy .rows() also caches TupleDesc names outside row loop & skips dropped column
  let raw = Select(tbl.id, tbl.txt, tbl.note).From(tbl).OrderBy(tbl.id.asc).rows()
  doAssert raw.len == 3
  doAssert raw[0]["txt"] == ""
  doAssert not raw[1].hasKey("txt") or raw[1]["txt"] == ""
  doAssert not raw[0].hasKey("dropped_mid")

  let fmtOpt = proc(o: Option[string]): string =
    if o.isNone: "NONE"
    else: "SOME(" & o.get & ")"

  result = fmtOpt(typed[0].txt) & "|" & fmtOpt(typed[1].txt) & "|" & fmtOpt(typed[2].txt) & "|" & fmtOpt(typed[2].note)

proc sb_dml_returning*(): string =
  dropTempIfExists("sb_ret_tbl")
  discard fetchRawRows("CREATE TEMP TABLE sb_ret_tbl (id serial PRIMARY KEY, txt text NOT NULL, qty int4 NOT NULL)")

  let tbl = table("sb_ret_tbl")
  let inserted = all[RetRow](
    InsertInto(tbl, "txt", "qty")
      .Values("alpha", 10)
      .Values("beta", 20)
      .Returning("id", "txt", "qty")
  )
  doAssert inserted.len == 2

  let singleId = InsertInto(tbl, "txt", "qty")
    .Values("gamma", 30)
    .Returning("id")
    .scalar(int64)
  doAssert singleId == 3'i64

  let firstIns = InsertInto(tbl, "txt", "qty")
    .Values("delta", 40)
    .Returning("id", "txt", "qty")
    .first(RetRow)
  doAssert firstIns.isSome and firstIns.get.txt == "delta" and firstIns.get.qty == 40'i32

  let updated = Update(tbl)
    .Set(tbl.qty, 99)
    .Where(tbl.txt == "beta")
    .Returning("id", "txt", "qty")
    .fetch(RetRow)
  doAssert updated.len == 1 and updated[0].qty == 99'i32

  let deleted = DeleteFrom(tbl)
    .Where(tbl.txt == "alpha")
    .Returning("id", "txt", "qty")
    .all(RetRow)
  doAssert deleted.len == 1 and deleted[0].txt == "alpha"

  let valScalar = scalar[int32](Values(Row(123'i32)))
  let selCount = Select(tbl.id).From(tbl).fetchCount()
  result = "ins=" & $inserted.len & "|sid=" & $singleId & "|first=" & firstIns.get.txt &
           "|upd=" & $updated[0].qty & "|del=" & deleted[0].txt & "|val=" & $valScalar & "|rem=" & $selCount

proc sb_binary_types_roundtrip*(): string =
  dropTempIfExists("sb_types_tbl")
  discard fetchRawRows("""
    CREATE TEMP TABLE sb_types_tbl (
      id int8 PRIMARY KEY,
      code text NOT NULL,
      i16 int2 NOT NULL,
      i32 int4 NOT NULL,
      i64 int8 NOT NULL,
      oid_col oid NOT NULL,
      f32 float4 NOT NULL,
      f64 float8 NOT NULL,
      f_nan float8 NOT NULL,
      f_inf float8 NOT NULL,
      flag bool NOT NULL,
      txt text NOT NULL,
      vchar varchar(64) NOT NULL,
      doc jsonb NOT NULL,
      raw_json json NOT NULL,
      payload bytea NOT NULL,
      uid uuid NOT NULL,
      dt date NOT NULL,
      ts timestamp NOT NULL,
      tstz timestamptz NOT NULL,
      iv interval NOT NULL,
      num numeric(18, 4) NOT NULL,
      color_enum sb_color NOT NULL,
      color_text text NOT NULL,
      iarr int4[] NOT NULL,
      i8arr int8[] NOT NULL,
      farr float8[] NOT NULL,
      barr bool[] NOT NULL,
      sarr text[] NOT NULL
    )
  """)

  let uidVal = parsePgUuid("550e8400-e29b-41d4-a716-446655440000")
  let dtVal = initPgDate(2025, 3, 15)
  let tsVal = initPgTimestamp(2025, 3, 15, 10, 20, 30, 500000)
  let tstzVal = initPgTimestampTz(2025, 3, 15, 10, 20, 30, 250000)
  let ivVal = initPgInterval(months = 2, days = 5, hours = 3, minutes = 4, seconds = 6)
  let numVal = pgNumeric("987654321.1250")
  let bytesVal = toPgBytea(@[byte 0x00, 0xDE, 0xAD, 0x00, 0xBE, 0xEF])
  let jVal = %*{"k": "v", "n": 7}

  let tbl = table("sb_types_tbl")
  # Parameterized binary insert across scalars, bytea, uuid, temporals, numeric, arrays, and SQLi string
  let inj = "x'); DROP TABLE pg_temp.sb_types_tbl; -- $1"
  discard InsertInto(tbl,
    "id", "code", "i16", "i32", "i64", "oid_col", "f32", "f64", "f_nan", "f_inf",
    "flag", "txt", "vchar", "doc", "raw_json", "payload", "uid", "dt", "ts", "tstz",
    "iv", "num", "color_enum", "color_text", "iarr", "i8arr", "farr", "barr", "sarr"
  ).Values(
    SbAccountId(9001'i64), SbCode("ACC-9"), -123'i16, 456789'i32, 9000000000001'i64,
    0x80000042'u32, 1.5'f32, 2.25'f64, NaN, Inf,
    true, toPgText(inj), "vchar-ok", jVal, raw("'{\"rk\":42}'::json"), bytesVal,
    uidVal, dtVal, tsVal, tstzVal, ivVal, numVal,
    raw("'green'::sb_color"), scBlue,
    @[1'i32, -2'i32, 3'i32], @[10'i64, 20'i64], @[1.25'f64, 2.5'f64],
    @[true, false], @["one", "", "three"]
  ).run()

  # Also test insertFrom & insertManyFrom in live DB
  dropTempIfExists("sb_bulk_tbl")
  discard fetchRawRows("CREATE TEMP TABLE sb_bulk_tbl (label text NOT NULL, score int8 NOT NULL, active bool NOT NULL)")
  discard spiInsertFrom(FullInsertItem(label: "one", score: 11'i64, active: true), "sb_bulk_tbl")
  discard spiInsertManyFrom(@[
    FullInsertItem(label: "two", score: 22'i64, active: false),
    FullInsertItem(label: "three", score: 33'i64, active: true)
  ], "sb_bulk_tbl")
  let bulkSum = fetchScalar[int64](Select(raw("sum(score)") as "s").From("sb_bulk_tbl"))
  doAssert bulkSum == 66'i64

  # Parameterized SELECT decoding all binary fields including enum OID and NULL inside sarr
  discard fetchRawRows("UPDATE pg_temp.sb_types_tbl SET sarr = ARRAY['one', NULL, '', 'four']::text[]")

  let rows = fetch[FullBinaryRow](Select(raw("*")).From(tbl).Where(tbl.id == 9001'i64 and tbl.txt == inj))
  doAssert rows.len == 1
  let r = rows[0]
  doAssert int64(r.id) == 9001'i64
  doAssert string(r.code) == "ACC-9"
  doAssert r.i16 == -123'i16 and r.i32 == 456789'i32 and r.i64 == 9000000000001'i64
  doAssert r.oid_col == 0x80000042'u32
  doAssert r.f32 == 1.5'f32 and r.f64 == 2.25'f64
  doAssert classify(r.f_nan) == fcNan and r.f_inf == Inf
  doAssert r.flag == true
  doAssert $r.txt == inj
  doAssert r.vchar == "vchar-ok"
  doAssert r.doc["k"].getStr == "v" and r.doc["n"].getInt == 7
  doAssert r.raw_json["rk"].getInt == 42
  doAssert r.payload.toBytes == @[byte 0x00, 0xDE, 0xAD, 0x00, 0xBE, 0xEF]
  doAssert $r.uid == "550e8400-e29b-41d4-a716-446655440000"
  doAssert r.dt.days == dtVal.days
  doAssert r.ts.usec == tsVal.usec
  doAssert r.tstz.usec == tstzVal.usec
  doAssert r.iv.months == 2 and r.iv.days == 5 and r.iv.usec == ivVal.usec
  doAssert $r.num == "987654321.1250"
  doAssert r.color_enum == scGreen and r.color_text == scBlue
  doAssert r.iarr == @[1'i32, -2'i32, 3'i32]
  doAssert r.i8arr == @[10'i64, 20'i64]
  doAssert r.farr == @[1.25'f64, 2.5'f64]
  doAssert r.barr == @[true, false]
  doAssert r.sarr == @[some("one"), none(string), some(""), some("four")]

  # Complex CTE + CaseWhen + Having + Between + inList + Subquery query
  let bt = table("sb_bulk_tbl")
  let sa = table("s_agg")
  let subCte = Select(bt.score).From(bt).Where(bt.active == true)
  let aggCte = Select(bt.active, sum(bt.score) as "tot")
    .From(bt)
    .GroupBy(bt.active)
    .Having(sum(bt.score) > 20)
  let cQ = WithCte("s_pos", subCte)
    .AndWith("s_agg", aggCte)
    .Select(sa.tot as "t")
    .From(sa)
    .Where(sa.tot.between(30, 60) and sa.active == true)
  let cteTotal = cQ.scalar(int64)
  doAssert cteTotal == 44'i64

  result = "ok:oid=" & $r.oid_col & ":bytes=" & $r.payload.len & ":num=" & $r.num &
           ":enum=" & $r.color_enum & ":bulk=" & $bulkSum & ":cte=" & $cteTotal

proc sb_custom_hook*(): string =
  dropTempIfExists("sb_hook_tbl")
  discard fetchRawRows("CREATE TEMP TABLE sb_hook_tbl (id int4 NOT NULL, badge text NOT NULL, opt_badge text)")
  let t = table("sb_hook_tbl")
  discard InsertInto(t, "id", "badge", "opt_badge")
    .Values(1, "gold", some("silver"))
    .Values(2, "bronze", none(string))
    .run()

  let rows = Select(t.id, t.badge, t.opt_badge).From(t).OrderBy(t.id.asc).fetch(HookRow)
  doAssert rows.len == 2
  doAssert rows[0].badge.tag == "ext:gold"
  doAssert rows[0].opt_badge.isSome and rows[0].opt_badge.get.tag == "ext:silver"
  doAssert rows[1].opt_badge.isNone

  let singleBadge = Select(t.badge).From(t).Where(t.id == 1).scalar(PluginBadge)
  var streamed = ""
  for sr in stream[HookRow](Select(t.id, t.badge, t.opt_badge).From(t).OrderBy(t.id.asc), batchSize = 1):
    if streamed.len > 0: streamed.add(",")
    streamed.add(sr.badge.tag)

  result = singleBadge.tag & "|" & streamed

proc sb_prepared_plans*(): string =
  dropTempIfExists("sb_plan_tbl")
  discard fetchRawRows("CREATE TEMP TABLE sb_plan_tbl (id serial PRIMARY KEY, name text NOT NULL, qty int4 NOT NULL)")

  var insPlan = spiPrepare(
    "INSERT INTO pg_temp.sb_plan_tbl (name, qty) VALUES ($1, $2) RETURNING id, name, qty",
    [TEXTOID, INT4OID],
    keep = false
  )
  let r1 = fetchPlan[PlanRow](insPlan, [toBoundParam("p1"), toBoundParam(10'i32)], readOnly = false)
  let nAff = executePlan(insPlan, [toBoundParam("p2"), toBoundParam(20'i32)], readOnly = false)
  doAssert r1.len == 1 and r1[0].name == "p1" and r1[0].qty == 10'i32
  doAssert nAff == 1

  var selPlan = spiPrepare(
    "SELECT id, name, qty FROM pg_temp.sb_plan_tbl WHERE qty >= $1 ORDER BY id",
    [INT4OID],
    keep = false
  )
  let fetched = fetchPlan[PlanRow](selPlan, [toBoundParam(15'i32)], readOnly = true)
  doAssert fetched.len == 1 and fetched[0].name == "p2"

  # Double-free safety
  selPlan.free()
  selPlan.free()
  insPlan.free()
  insPlan.free()

  var postFreeRejected = false
  try:
    discard executePlan(selPlan, [toBoundParam(10'i32)])
  except ValueError:
    postFreeRejected = true
  doAssert postFreeRejected

  result = "ins1=" & r1[0].name & "|fetched=" & fetched[0].name & "|freed=" & $postFreeRejected

proc sb_cursor_streaming*(): string =
  dropTempIfExists("sb_stream_tbl")
  discard fetchRawRows("""
    CREATE TEMP TABLE sb_stream_tbl AS
    SELECT g AS id, (g % 5) AS grp, (g * 10)::int8 AS val
    FROM generate_series(1, 250) AS g
  """)

  let tbl = table("sb_stream_tbl")
  let qAll = Select(tbl.id, tbl.grp, tbl.val).From(tbl).OrderBy(tbl.id.asc)

  var totalSum = 0'i64
  var totalCount = 0
  for r in stream[StreamRow](qAll, batchSize = 17):
    inc totalCount
    totalSum += r.val
  doAssert totalCount == 250
  doAssert totalSum == 313750'i64 # 10 * 250 * 251 / 2 = 313750

  # Early break closes portal cleanly
  var earlyCount = 0
  for r in stream[StreamRow](qAll, batchSize = 10):
    inc earlyCount
    if earlyCount == 25:
      break
  doAssert earlyCount == 25
  let curAfterBreak = fetchScalar[int64](Select(raw("count(*)") as "c").From("pg_cursors"))
  doAssert curAfterBreak == 0'i64

  # Exception thrown inside stream loop closes portal cleanly
  var caughtMidStream = false
  try:
    for r in stream[StreamRow](qAll, batchSize = 10):
      if r.id == 12'i32:
        raise newException(ValueError, "abort mid-stream")
  except ValueError:
    caughtMidStream = true
  doAssert caughtMidStream
  let curAfterErr = fetchScalar[int64](Select(raw("count(*)") as "c").From("pg_cursors"))
  doAssert curAfterErr == 0'i64

  # fetchBatches sizes check
  var batchLens: seq[int] = @[]
  for batch in fetchBatches[StreamRow](qAll, batchSize = 100):
    batchLens.add(batch.len)
  doAssert batchLens == @[100, 100, 50]

  # Manual SpiCursor + idempotent close
  var cur = spiCursorOpen("sb_manual_cur", "SELECT id, grp, val FROM pg_temp.sb_stream_tbl WHERE grp = $1 ORDER BY id", [toBoundParam(0'i32)])
  let b1 = spiCursorFetch[StreamRow](cur, 15)
  let b2 = spiCursorFetch[StreamRow](cur, 100)
  doAssert b1.len == 15 and b2.len == 35
  spiCursorClose(cur)
  spiCursorClose(cur)
  let curAfterManual = fetchScalar[int64](Select(raw("count(*)") as "c").From("pg_cursors"))
  doAssert curAfterManual == 0'i64

  # Negative / zero batchSize check
  var badBatchRejected = false
  try:
    for _ in stream[StreamRow](qAll, batchSize = 0):
      discard
  except ValueError:
    badBatchRejected = true
  doAssert badBatchRejected

  result = "sum=" & $totalSum & "|early=" & $earlyCount & "|err=" & $caughtMidStream &
           "|batches=100,100,50|manual=" & $(b1.len + b2.len) & "|cursors=0|bad=" & $badBatchRejected

proc sb_nonatomic_tx*(seed: int32) =
  let tbl = table("sb_tx_log")
  spiNonAtomic:
    # 1. Commit persistent row
    discard InsertInto(tbl, "id", "tag").Values(seed, "commit_1").run()
    spiCommit()

    # 2. Rollback volatile row
    discard InsertInto(tbl, "id", "tag").Values(seed + 1, "rollback_1").run()
    spiRollback()

    # 3. Commit-and-chain persistent row
    discard InsertInto(tbl, "id", "tag").Values(seed + 2, "commit_chain").run()
    spiCommitAndChain()

    # 4. Rollback-and-chain volatile row
    discard InsertInto(tbl, "id", "tag").Values(seed + 3, "rollback_chain").run()
    spiRollbackAndChain()

    # 5. Unique PK violation error inside savepoint -> catch -> rollback recovery -> insert & commit
    var caughtDup = false
    savepoint:
      discard InsertInto(tbl, "id", "tag").Values(seed, "dup_should_fail").run()
    do:
      caughtDup = (err != nil)
    doAssert caughtDup

    # 6. Prepared plan + fetch inside non-atomic mode, then commit
    var p = spiPrepare("INSERT INTO sb_tx_log (id, tag) VALUES ($1, $2)", [INT4OID, TEXTOID])
    discard executePlan(p, [toBoundParam(seed + 4), toBoundParam("after_recovery")])
    p.free()

    let cnt = Select(raw("count(*)") as "c").From(tbl).scalar(int64)
    doAssert cnt == 3'i64
    spiCommit()

proc sb_reject_null_byte*(): string =
  var rejectedSql = false
  try:
    discard fetchRawRows("SELECT 'bad\0sql'")
  except ValueError:
    rejectedSql = true

  var rejectedParam = false
  let t = table("pg_class")
  try:
    discard Select(t.relname).From(t).Where(t.relname == "bad\0param").rows()
  except ValueError:
    rejectedParam = true

  result = "sql=" & $rejectedSql & "|param=" & $rejectedParam
