import pgxcrown
import std/strutils

var
  obsEnabledGuc: GucVar[bool]
  totalParsedQueries: int64 = 0
  selectQueries: int64 = 0
  totalExecEndQueries: int64 = 0

proc isObserverControlSql(sqlText: string): bool {.inline.} =
  "{{project_snake}}_hook_" in sqlText

proc onPostParseObserve(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) =
  discard jstate
  if not obsEnabledGuc.get():
    return
  if isObserverControlSql(pstate.sourceText):
    return
  if query != nil and query.commandType in {CMD_SELECT, CMD_INSERT, CMD_UPDATE, CMD_DELETE}:
    inc totalParsedQueries
    if query.commandType == CMD_SELECT:
      inc selectQueries

proc onExecEndObserve(info: ExecutorQueryInfo) =
  if not obsEnabledGuc.get():
    return
  if isObserverControlSql(info.sourceText):
    return
  if info.operation in {pgxCmdSelect, pgxCmdInsert, pgxCmdUpdate, pgxCmdDelete}:
    inc totalExecEndQueries

proc initObservabilityHooks*() {.pgxInit.} =
  obsEnabledGuc = defineGucBool(
    "{{guc_prefix}}.enabled",
    "Enable {{project_name}} query observability hooks",
    "Toggles composable post_parse_analyze and ExecutorEnd metrics collection",
    bootValue = true,
    context = gcUserset
  )
  reserveGucPrefix("{{guc_prefix}}")
  registerPostParseHook(onPostParseObserve, hpPre)
  registerExecutorEndHook(onExecEndObserve, hpPre)

proc {{project_snake}}_hook_enabled*(): bool {.volatile.} =
  obsEnabledGuc.get()

proc {{project_snake}}_hook_reset*(): bool {.volatile.} =
  totalParsedQueries = 0
  selectQueries = 0
  totalExecEndQueries = 0
  true

proc {{project_snake}}_hook_stats*(): string {.volatile.} =
  let installed = isPostParseHookInstalled() and isExecutorEndHookInstalled()
  "label={{hook_label}}|installed=" & $installed &
    "|enabled=" & $obsEnabledGuc.get() &
    "|parsed=" & $totalParsedQueries &
    "|selects=" & $selectQueries &
    "|exec_end=" & $totalExecEndQueries
