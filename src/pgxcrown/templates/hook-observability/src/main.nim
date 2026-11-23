import pgxcrown
import pgxcrown/hooks/post_parse_hook

var
  cPostParseAnalyzeHook {.importc: "post_parse_analyze_hook", header: "parser/analyze.h".}: post_parse_analyze_hook_type
  prevPostParseHook: post_parse_analyze_hook_type = nil
  hookInstalled = false
  totalParsedQueries: int64 = 0
  selectQueries: int64 = 0

proc observePostParse(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.} =
  inc totalParsedQueries
  if query != nil and query.commandType == CMD_SELECT:
    inc selectQueries
  if prevPostParseHook != nil:
    prevPostParseHook(pstate, query, jstate)

proc installObservabilityHook() {.pgxInit.} =
  if not hookInstalled:
    if cPostParseAnalyzeHook != observePostParse:
      prevPostParseHook = cPostParseAnalyzeHook
      cPostParseAnalyzeHook = observePostParse
    hookInstalled = true

proc {{project_snake}}_hook_reset*(): bool {.volatile.} =
  totalParsedQueries = 0
  selectQueries = 0
  true

proc {{project_snake}}_hook_stats*(): string {.volatile.} =
  "label={{hook_label}}|installed=" & $hookInstalled &
    "|total=" & $totalParsedQueries &
    "|selects=" & $selectQueries
