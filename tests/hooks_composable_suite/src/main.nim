import std/strutils
import pgxcrown

var
  gExecutedQueries: int64 = 0
  gSecondHookHits: int64 = 0
  gTotalRowsProcessed: uint64 = 0
  gSelectQueries: int64 = 0
  gInsertQueries: int64 = 0
  gUpdateQueries: int64 = 0
  gDeleteQueries: int64 = 0
  gBlockedDrops: int64 = 0
  gAllowedDrops: int64 = 0
  gLastUtilTag: FixedString[32]

proc isResetQuery(sqlText: string): bool {.inline.} =
  "reset_hook_counters" in sqlText

proc onExecStartMetrics(info: ExecutorQueryInfo, eflags: cint) =
  let sql = info.sourceText
  if isResetQuery(sql):
    return
  inc gExecutedQueries
  case info.operation
  of pgxCmdSelect: inc gSelectQueries
  of pgxCmdInsert: inc gInsertQueries
  of pgxCmdUpdate: inc gUpdateQueries
  of pgxCmdDelete: inc gDeleteQueries
  else: discard

proc onExecStartComposedSecond(info: ExecutorQueryInfo, eflags: cint) =
  if not isResetQuery(info.sourceText):
    inc gSecondHookHits

proc onExecEndMetrics(info: ExecutorQueryInfo) =
  if isResetQuery(info.sourceText):
    return
  gTotalRowsProcessed += info.rowsProcessed

proc onProcessUtilityAudit(info: UtilityStmtInfo) =
  let tag = info.tagName
  if tag != "TransactionStmt":
    discard gLastUtilTag.trySetStr(tag)
  if info.isDropTable:
    if info.dropTargetsContain("protected_audit_tbl"):
      inc gBlockedDrops
      raisePgError(
        "42501",
        "DROP TABLE protected_audit_tbl is blocked by hooks_composable_suite",
        detail = "Targets: " & info.dropTargetsCsv,
        hint = "protected_audit_tbl cannot be dropped while hooks_composable_suite is active"
      )
    else:
      inc gAllowedDrops

proc initComposableHooks*() {.pgxInit.} =
  discard gLastUtilTag.trySetStr("none")
  registerExecutorStartHook(onExecStartMetrics, hpPre)
  registerExecutorStartHook(onExecStartComposedSecond, hpPre)
  registerExecutorEndHook(onExecEndMetrics, hpPre)
  registerProcessUtilityHook(onProcessUtilityAudit, hpPre)

proc hooks_installed*(): bool {.volatile.} =
  isExecutorStartHookInstalled() and
  isExecutorEndHookInstalled() and
  isProcessUtilityHookInstalled() and
  executorStartHookCount() == 2 and
  executorEndHookCount() == 1 and
  processUtilityHookCount() == 1

proc reset_hook_counters*(): string {.volatile.} =
  gExecutedQueries = 0
  gSecondHookHits = 0
  gTotalRowsProcessed = 0
  gSelectQueries = 0
  gInsertQueries = 0
  gUpdateQueries = 0
  gDeleteQueries = 0
  gBlockedDrops = 0
  gAllowedDrops = 0
  discard gLastUtilTag.trySetStr("none")
  "reset_ok"

proc hook_query_count*(): int64 {.volatile.} =
  gExecutedQueries

proc hook_second_count*(): int64 {.volatile.} =
  gSecondHookHits

proc hook_rows_processed*(): int64 {.volatile.} =
  int64(gTotalRowsProcessed)

proc hook_stats*(): string {.volatile.} =
  "queries=" & $gExecutedQueries &
  ",second=" & $gSecondHookHits &
  ",rows=" & $gTotalRowsProcessed &
  ",select=" & $gSelectQueries &
  ",insert=" & $gInsertQueries &
  ",update=" & $gUpdateQueries &
  ",delete=" & $gDeleteQueries &
  ",blocked_drops=" & $gBlockedDrops &
  ",allowed_drops=" & $gAllowedDrops &
  ",last_util=" & $gLastUtilTag

proc hook_udf_echo*(msg: string): string {.immutable, parallelSafe.} =
  "udf:" & msg
