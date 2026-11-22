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
