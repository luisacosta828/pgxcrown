import pgxcrown
import pgxcrown/syscache
import pgxcrown/catalog/[pg_proc, pg_type]
import std/[options, strutils]
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

var archProcAcc {.global.}: int32 = 0

proc v30_volatile_proc*(delta: int32) {.volatile.} =
  archProcAcc += delta

proc v30_explicit_void_proc*(delta: int32): void {.volatile, securityDefiner, searchPath: "public, pg_catalog".} =
  archProcAcc += delta * 10'i32

proc v30_proc_counter*(): int32 {.volatile.} =
  archProcAcc

proc v30_call_procs_dfc*(a, b: int32): int32 {.volatile.} =
  v30_volatile_proc(a)
  v30_explicit_void_proc(b)
  return archProcAcc

proc v30_syscache_probe*(): string {.stable.} =
  var parts: seq[string] = @[]

  let int4Tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(23.Oid))
  doAssert HeapTupleIsValid(int4Tup)
  try:
    let tName = $get_pg_type_name(int4Tup)
    let tLen = get_pg_type_len(int4Tup)
    let tDef = get_pg_type_defaultvalue(int4Tup)
    let defTag =
      if tDef == nil:
        "NULL"
      else:
        let s = $tDef
        basic.pfree(tDef)
        s
    parts.add("type=" & tName & ":" & $tLen & ":" & defTag)
  finally:
    ReleaseSysCache(int4Tup)

  let echoRows = fetchRawRows(
    "SELECT oid::bigint AS id FROM pg_proc WHERE proname = 'v30_echo' AND pronargs = 1 AND proargtypes[0] = 23 LIMIT 1"
  )
  doAssert echoRows.len == 1
  let echoOid = Oid(parseBiggestInt(echoRows[0]["id"]))
  let procTup = SearchSysCache1(PROCOID, ObjectIdGetDatum(echoOid))
  doAssert HeapTupleIsValid(procTup)
  try:
    let pName = $get_pg_proc_name(procTup)
    let pNargs = get_pg_proc_nargs(procTup)
    let arg0 = get_pg_proc_arg_oid(procTup, 0)
    let argOob = get_pg_proc_arg_oid(procTup, 1)
    parts.add("proc=" & pName & ":" & $pNargs & ":" & $arg0 & ":" & $argOob)
  finally:
    ReleaseSysCache(procTup)

  let famRows = fetchRawRows(
    "SELECT f.oid::bigint AS id FROM pg_opfamily f JOIN pg_am a ON a.oid = f.opfmethod WHERE a.amname = 'btree' AND f.opfname = 'integer_ops' LIMIT 1"
  )
  doAssert famRows.len == 1
  let famOid = Oid(parseBiggestInt(famRows[0]["id"]))
  let amopHit = SearchSysCache4(
    AMOPSTRATEGY,
    ObjectIdGetDatum(famOid),
    ObjectIdGetDatum(23.Oid),
    ObjectIdGetDatum(23.Oid),
    Int16GetDatum(3'i16)
  )
  let hitOk = HeapTupleIsValid(amopHit)
  if hitOk:
    ReleaseSysCache(amopHit)

  let amopMiss = SearchSysCache4(
    AMOPSTRATEGY,
    ObjectIdGetDatum(famOid),
    ObjectIdGetDatum(23.Oid),
    ObjectIdGetDatum(23.Oid),
    Int16GetDatum(99'i16)
  )
  let missOk = not HeapTupleIsValid(amopMiss)
  if HeapTupleIsValid(amopMiss):
    ReleaseSysCache(amopMiss)

  parts.add("amop4=" & $hitOk & "/" & $missOk)
  return parts.join("|")

proc v30_f32_double*(x: float32): float32 {.immutable, parallelSafe.} =
  x * 2.0'f32

proc v30_float32_vec_sum*(v: PgVector[float32]): float64 {.immutable, parallelSafe.} =
  var total = 0.0
  for item in v:
    total += float64(v30_f32_double(item))
  total

proc v30_metrics_check*(m: ArchMetrics): string {.immutable, parallelSafe.} =
  "ratio=" & $m.ratio & "|flag=" & $m.flag & "|tiny=" & $int(m.tiny)

proc v30_converter_roundtrip*(): string {.immutable, parallelSafe.} =
  let origF64: float64 = 3.141592653589793
  let dF64: Datum = origF64
  let backF64: float64 = dF64

  let dBool: Datum = true
  let backBool: bool = dBool

  let dInt8: Datum = -7'i8
  let backInt8: int8 = dInt8

  let dZeroStr: string = Datum(0)
  let dOkStr: Datum = "v30_conv"
  let backStr: string = dOkStr

  var srcVec = @[10'i32, 20'i32, 30'i32]
  let pv = toPgVector(srcVec)
  srcVec = @[99'i32]
  let backVecSeq: seq[int32] = pv

  let t = table("items", "i")
  let pt = toPgText("hi")
  let qpPt: QueryParam = pt
  let u8Val: uint8 = 7'u8
  let qbSql = $Select(sqlIdent("k"), t.v)
    .From(t)
    .Where(t.x == none(string) and t.u == u8Val and t.f == NaN)
    .GroupBy(sqlIdent("k"))
    .OrderBy(sqlIdent("k"))

  "f64=" & (if abs(backF64 - origF64) < 1e-14: "exact" else: "lossy") &
    "|bool=" & $backBool &
    "|i8=" & $int(backInt8) &
    "|str0=" & $dZeroStr.len &
    "|str=" & backStr &
    "|vec=" & $backVecSeq &
    "|pt=" & $qpPt &
    "|qb=" & $qbSql.contains("'NaN'::float8") & "/" & $qbSql.contains("IS NULL") & "/" & $qbSql.contains("GROUP BY \"k\"")

proc v30_qb_spi_live*(): string {.volatile.} =
  type
    LiveTagId = distinct int64
    LiveState = enum
      lsOpen = "open"
      lsClosed = "closed"

  let t = table("v30_qb_items", "i")
  # Compile-time verification under full `import pgxcrown` that raw Datum is rejected
  doAssert not compiles(toParam(Datum(1)))
  doAssert not compiles(toQueryParam(Datum(1)))
  doAssert not compiles(formatSqlValue(Datum(1)))
  doAssert not compiles(t.u == Datum(1))
  doAssert not compiles(t.u != Datum(1))
  doAssert not compiles(parseValue[Datum]("1"))
  doAssert not compiles(Select(Datum(1) as "x"))
  doAssert not compiles(Datum(1).desc)
  doAssert not compiles(Datum(1).asc)
  doAssert $Select(toPgText("hi") as "x") == "SELECT 'hi' AS \"x\""
  doAssert $toParam(some(toPgText("hi"))) == "'hi'"

  discard fetchRawRows("DO $$ BEGIN IF to_regclass('pg_temp.v30_qb_items') IS NOT NULL THEN DROP TABLE pg_temp.v30_qb_items; END IF; END $$")
  discard fetchRawRows("""
    CREATE TEMP TABLE v30_qb_items (
      k text NOT NULL,
      note text,
      u int4 NOT NULL,
      score float8 NOT NULL,
      tag_ids bigint[] NOT NULL,
      states text[] NOT NULL,
      vec int4[] NOT NULL
    )
  """)
  try:
    let emptyTags = newSeq[LiveTagId]()
    let emptyStates = newSeq[LiveState]()
    discard InsertInto(t, t.k, t.note, t.u, t.score, t.tag_ids, t.states, t.vec)
      .Values(
        toPgText("alpha"),
        none(string),
        7'u8,
        NaN,
        emptyTags,
        emptyStates,
        toPgVector(@[10'i32, 20'i32])
      )
      .Values(
        toPgText("beta"),
        some("present"),
        byte(250'u8),
        Inf,
        @[LiveTagId(101'i64), LiveTagId(202'i64)],
        @[LiveState.lsOpen],
        toPgVector(@[30'i32])
      )
      .run()

    let r1 = Select(
        sqlIdent("k"),
        raw("min(cardinality(i.tag_ids))") as "tc",
        raw("min(cardinality(i.states))") as "sc",
        raw("min(i.vec::text)") as "vt"
      )
      .From(t)
      .Where(t.note == none(string) and t.u == 7'u8 and t.score == NaN)
      .GroupBy(sqlIdent("k"))
      .OrderBy(sqlIdent("k"))
      .rows()
    doAssert r1.len == 1

    let r2 = Select(
        sqlIdent("k"),
        raw("min(cardinality(i.tag_ids))") as "tc",
        raw("min(cardinality(i.states))") as "sc",
        raw("min(i.vec::text)") as "vt"
      )
      .From(t)
      .Where(t.note != none(string) and t.u == byte(250'u8) and t.score == Inf and t.k == toPgText("beta"))
      .GroupBy(sqlIdent("k"))
      .OrderBy(sqlIdent("k"))
      .rows()
    doAssert r2.len == 1

    return "row1=" & r1[0]["k"] & ":" & r1[0]["tc"] & ":" & r1[0]["sc"] & ":" & r1[0]["vt"] &
      "|row2=" & r2[0]["k"] & ":" & r2[0]["tc"] & ":" & r2[0]["sc"] & ":" & r2[0]["vt"]
  finally:
    discard fetchRawRows("DROP TABLE IF EXISTS v30_qb_items")
