import pgxcrown
import std/[algorithm, atomics, options, strutils]
import ./interop_plugin

export interop_plugin

type
  InteropEventRow {.noSql.} = object
    id*: int32
    tag*: InteropTag
    note*: Option[string]
    qty*: int32

var
  gBatchLimitGuc: GucVar[int32]
  gStrictAuditGuc: GucVar[bool]
  gSecretTokenGuc: GucVar[string]

  gExecSelects {.global.}: int64 = 0
  gExecInserts {.global.}: int64 = 0
  gExecRows {.global.}: uint64 = 0
  gBlockedDrops {.global.}: int64 = 0
  gAllowedDrops {.global.}: int64 = 0

  gCommittedOps {.global.}: int64 = 0
  gAbortedOps {.global.}: int64 = 0
  gSubXactLog {.global.}: seq[string] = @[]
  gSubXactHandle {.global.}: SubXactHandle = InvalidSubXactHandle

proc recordSubEvent(msg: string) =
  pgxWithLibcAlloc:
    var copyStr = newString(msg.len)
    if msg.len > 0:
      copyMem(addr copyStr[0], unsafeAddr msg[0], msg.len)
    gSubXactLog.add(copyStr)

proc isInternalHookCtrlQuery(sqlText: string): bool {.inline.} =
  "interop_hook_" in sqlText or "interop_reset_hooks" in sqlText

proc onInteropExecEnd(info: ExecutorQueryInfo) =
  let sqlText = info.sourceText
  if isInternalHookCtrlQuery(sqlText):
    return
  if "interop_probe_tbl" notin sqlText:
    return
  gExecRows += info.rowsProcessed
  case info.operation
  of pgxCmdSelect: inc gExecSelects
  of pgxCmdInsert: inc gExecInserts
  else: discard

proc onInteropProcessUtility(info: UtilityStmtInfo) =
  if info.isDropTable:
    if info.dropTargetsContain("interop_protected_tbl"):
      inc gBlockedDrops
      raisePgError(
        "42501",
        "DROP TABLE interop_protected_tbl blocked by v32_v33_interop_suite",
        detail = "Targets: " & info.dropTargetsCsv,
        hint = "interop_protected_tbl is protected"
      )
    elif info.dropTargetsContain("interop_scratch_tbl"):
      inc gAllowedDrops

proc interop_init*() {.pgxInit.} =
  gBatchLimitGuc = defineGucInt(
    "v32interop.batch_limit",
    "Batch query row limit",
    "User-configurable maximum rows fetched per interop query",
    bootValue = 25,
    minVal = 1,
    maxVal = 500,
    context = gcUserset
  )
  gStrictAuditGuc = defineGucBool(
    "v32interop.strict_audit",
    "Strict policy mode",
    "Superuser-only strict validation toggle",
    bootValue = true,
    context = gcSuset
  )
  gSecretTokenGuc = defineGucString(
    "v32interop.secret_token",
    "Superuser API secret token",
    "Protected parameter visible only to superusers",
    bootValue = "interop-secret-boot",
    context = gcSuset,
    superuserOnly = true
  )
  reserveGucPrefix("v32interop")
  registerExecutorEndHook(onInteropExecEnd, hpPre)
  registerProcessUtilityHook(onInteropProcessUtility, hpPre)

proc interop_status*(): string {.volatile.} =
  "plugin_inits=" & $gPluginInitRuns.load() &
    "|exec_end_hook=" & $isExecutorEndHookInstalled() &
    "|util_hook=" & $isProcessUtilityHookInstalled() &
    "|batch_limit=" & $gBatchLimitGuc.get() &
    "|strict_audit=" & $gStrictAuditGuc.get()

proc interop_secret_read*(): string {.volatile.} =
  discard getGuc("v32interop.secret_token")
  gSecretTokenGuc.get()

proc interop_reset_hooks*(): string {.volatile.} =
  gExecSelects = 0
  gExecInserts = 0
  gExecRows = 0
  gBlockedDrops = 0
  gAllowedDrops = 0
  "hooks_reset_ok"

proc interop_hook_stats*(): string {.volatile.} =
  "select=" & $gExecSelects &
    "|insert=" & $gExecInserts &
    "|rows=" & $gExecRows &
    "|blocked_drops=" & $gBlockedDrops &
    "|allowed_drops=" & $gAllowedDrops

proc interop_arm_subxact_probe*(): bool {.volatile.} =
  if gSubXactHandle.isValid:
    discard unregisterSubXactCallback(gSubXactHandle)
    gSubXactHandle = InvalidSubXactHandle
  pgxWithLibcAlloc:
    gSubXactLog.setLen(0)
    gSubXactHandle = registerSubXactCallback(proc(ev: SubXactEvent, mySubid, parentSubid: SubTransactionId) =
      if ev in {sxeCommitSub, sxeAbortSub}:
        recordSubEvent($ev & ":" & $(mySubid > parentSubid))
    )
  true

proc interop_take_subxact_log*(): string {.volatile.} =
  result = gSubXactLog.join("|")
  if result.len == 0:
    result = "<empty>"
  pgxWithLibcAlloc:
    gSubXactLog.setLen(0)
  if gSubXactHandle.isValid:
    discard unregisterSubXactCallback(gSubXactHandle)
    gSubXactHandle = InvalidSubXactHandle

proc interop_record_event*(tag: InteropTag, note: Option[string], qty: int32): int64 {.volatile.} =
  if gStrictAuditGuc.get() and qty < 0'i32:
    raisePgError("22023", "qty cannot be negative when v32interop.strict_audit is enabled")

  let t = table("interop_events")
  let newId = InsertInto(t, t.tag, t.note, t.qty)
    .Values(pluginToParam(tag), note, qty)
    .Returning("id")
    .scalar(int64)

  discard onCommit(proc() = inc gCommittedOps, once = true)
  discard onAbort(proc() = inc gAbortedOps, once = true)
  newId

proc interop_query_events*(tag: InteropTag): string {.volatile.} =
  let t = table("interop_events")
  let limitVal = int(gBatchLimitGuc.get())
  let rows = Select(t.id, t.tag, t.note, t.qty)
    .From(t)
    .Where(t.tag == pluginToParam(tag))
    .OrderBy(t.id.asc)
    .Limit(limitVal)
    .fetch(InteropEventRow)

  var parts: seq[string] = @[]
  for r in rows:
    let noteStr =
      if r.note.isNone: "NULL"
      elif r.note.get.len == 0: "EMPTY"
      else: "SOME(" & r.note.get & ")"
    parts.add($r.id & ":" & string(r.tag) & ":" & noteStr & ":" & $r.qty)
  parts.join("|")

proc interop_xact_counts*(): string {.volatile.} =
  "committed=" & $gCommittedOps & "|aborted=" & $gAbortedOps

proc interop_integrity_report*(): string {.stable.} =
  let intact = isCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  let violations = verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)
  let sha = loadedSoSha256(PgxExtensionName)
  var allHex64 = sha.len == 64
  for ch in sha:
    if ch notin {'0'..'9', 'a'..'f'}:
      allHex64 = false
  var vCodes: seq[string] = @[]
  for v in violations:
    vCodes.add(v.code & ":" & v.functionName)
  vCodes.sort()
  let vStr = if vCodes.len == 0: "NONE" else: vCodes.join(",")
  "intact=" & $intact & "|violations=" & $violations.len & "|codes=" & vStr & "|sha64=" & $allHex64 & "|fns_gt0=" & $(PgxCompiledFunctions.len > 0)

proc interop_assert_intact*(): string {.stable.} =
  assertCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  "INTACT"
