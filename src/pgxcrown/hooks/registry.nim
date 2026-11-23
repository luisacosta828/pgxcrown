## =============================================================================
## Pgxcrown Composable Hooks Registry (PG 14-18)
## =============================================================================
## Allows any pgxcrown extension (alongside UDFs, Shmem, BgWorkers, GUCs) to
## register multiple composable callbacks in {.pgxInit.} across:
##   - ExecutorStart, ExecutorRun, ExecutorFinish, ExecutorEnd
##   - ProcessUtility
##   - emit_log
##   - post_parse_analyze
##
## Callbacks are stored in process-lifetime C-safe storage via real_calloc /
## real_realloc / real_free (immune to PostgreSQL MemoryContext resets), and
## single-definition C trampolines execute in pure C so prev_* / standard_*
## siglongjmp errors never unwind past live Nim ARC objects or try/finally frames.
## =============================================================================

import std/os
import ../allocator
import ../reports/reports
import ./emit_hook
import ./post_parse_hook
import ./executor_hook
import ./utility_hook

export emit_hook
export post_parse_hook
export executor_hook
export utility_hook

const PgxRegistryCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxRegistryCHeadersDir).}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "pgx_hooks.h"
""".}

{.emit: """
/* Weak PostgreSQL fallback definitions so host unit tests that import pgxcrown
 * without mocking executor/utility hooks still link cleanly. Real postgres and
 * dedicated hook unit tests provide strong symbols that override these. */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) ExecutorStart_hook_type ExecutorStart_hook = NULL;
__attribute__((weak)) ExecutorRun_hook_type ExecutorRun_hook = NULL;
__attribute__((weak)) ExecutorFinish_hook_type ExecutorFinish_hook = NULL;
__attribute__((weak)) ExecutorEnd_hook_type ExecutorEnd_hook = NULL;
__attribute__((weak)) ProcessUtility_hook_type ProcessUtility_hook = NULL;
__attribute__((weak)) emit_log_hook_type emit_log_hook = NULL;
__attribute__((weak)) post_parse_analyze_hook_type post_parse_analyze_hook = NULL;

__attribute__((weak)) void standard_ExecutorStart(QueryDesc *qd, int eflags) {
    (void)qd; (void)eflags;
}
#if PG_VERSION_NUM >= 180000
__attribute__((weak)) void standard_ExecutorRun(QueryDesc *qd, ScanDirection dir, uint64 count) {
    (void)qd; (void)dir; (void)count;
}
#else
__attribute__((weak)) void standard_ExecutorRun(QueryDesc *qd, ScanDirection dir, uint64 count, bool execute_once) {
    (void)qd; (void)dir; (void)count; (void)execute_once;
}
#endif
__attribute__((weak)) void standard_ExecutorFinish(QueryDesc *qd) {
    (void)qd;
}
__attribute__((weak)) void standard_ExecutorEnd(QueryDesc *qd) {
    (void)qd;
}
__attribute__((weak)) void standard_ProcessUtility(
    PlannedStmt *pstmt, const char *queryString, bool readOnlyTree,
    ProcessUtilityContext context, ParamListInfo params,
    QueryEnvironment *queryEnv, DestReceiver *dest, QueryCompletion *qc)
{
    (void)pstmt; (void)queryString; (void)readOnlyTree; (void)context;
    (void)params; (void)queryEnv; (void)dest; (void)qc;
}
#endif

/* ============================================================================
 * Single Canonical C Hook Trampolines & State (one copy per extension/binary)
 * ============================================================================ */
ExecutorStart_hook_type      pgx_prev_executor_start      = NULL;
ExecutorRun_hook_type        pgx_prev_executor_run        = NULL;
ExecutorFinish_hook_type     pgx_prev_executor_finish     = NULL;
ExecutorEnd_hook_type        pgx_prev_executor_end        = NULL;
ProcessUtility_hook_type     pgx_prev_process_utility     = NULL;
emit_log_hook_type           pgx_prev_emit_log            = NULL;
post_parse_analyze_hook_type pgx_prev_post_parse_analyze  = NULL;

PgxNimExecStartFn            pgx_nim_exec_start_pre       = NULL;
PgxNimExecStartFn            pgx_nim_exec_start_post      = NULL;
PgxNimExecRunFn              pgx_nim_exec_run_pre         = NULL;
PgxNimExecRunFn              pgx_nim_exec_run_post        = NULL;
PgxNimExecQueryFn            pgx_nim_exec_finish_pre      = NULL;
PgxNimExecQueryFn            pgx_nim_exec_finish_post     = NULL;
PgxNimExecQueryFn            pgx_nim_exec_end_pre         = NULL;
PgxNimExecQueryFn            pgx_nim_exec_end_post        = NULL;
PgxNimProcessUtilityFn       pgx_nim_process_utility_pre  = NULL;
PgxNimProcessUtilityFn       pgx_nim_process_utility_post = NULL;
PgxNimEmitLogFn              pgx_nim_emit_log_pre         = NULL;
PgxNimEmitLogFn              pgx_nim_emit_log_post        = NULL;
PgxNimPostParseFn            pgx_nim_post_parse_pre       = NULL;
PgxNimPostParseFn            pgx_nim_post_parse_post      = NULL;

volatile sig_atomic_t        pgx_in_emit_log              = 0;

/* --- ExecutorStart --- */
void pgx_executor_start_trampoline(QueryDesc *qd, int eflags) {
    if (pgx_nim_exec_start_pre != NULL) {
        pgx_nim_exec_start_pre(qd, (int32)eflags);
    }
    if (pgx_prev_executor_start != NULL) {
        pgx_prev_executor_start(qd, eflags);
    } else {
        standard_ExecutorStart(qd, eflags);
    }
    if (pgx_nim_exec_start_post != NULL) {
        pgx_nim_exec_start_post(qd, (int32)eflags);
    }
}

void pgx_install_executor_start_hook(PgxNimExecStartFn pre_fn, PgxNimExecStartFn post_fn) {
    pgx_nim_exec_start_pre = pre_fn;
    pgx_nim_exec_start_post = post_fn;
    if (ExecutorStart_hook != pgx_executor_start_trampoline) {
        pgx_prev_executor_start = ExecutorStart_hook;
        ExecutorStart_hook = pgx_executor_start_trampoline;
    }
}

void pgx_uninstall_executor_start_hook(void) {
    if (ExecutorStart_hook == pgx_executor_start_trampoline) {
        ExecutorStart_hook = pgx_prev_executor_start;
    }
    pgx_prev_executor_start = NULL;
    pgx_nim_exec_start_pre = NULL;
    pgx_nim_exec_start_post = NULL;
}

bool pgx_is_executor_start_hook_installed(void) {
    return ExecutorStart_hook == pgx_executor_start_trampoline;
}

/* --- ExecutorRun (PG 18 3-arg vs PG 14-17 4-arg ABI guard) --- */
#if PG_VERSION_NUM >= 180000
void pgx_executor_run_trampoline(QueryDesc *qd, ScanDirection dir, uint64 count)
#else
void pgx_executor_run_trampoline(QueryDesc *qd, ScanDirection dir, uint64 count, bool execute_once)
#endif
{
#if PG_VERSION_NUM >= 180000
    bool execute_once = true;
#endif
    if (pgx_nim_exec_run_pre != NULL) {
        pgx_nim_exec_run_pre(qd, (int32)dir, count, execute_once);
    }
    if (pgx_prev_executor_run != NULL) {
#if PG_VERSION_NUM >= 180000
        pgx_prev_executor_run(qd, dir, count);
#else
        pgx_prev_executor_run(qd, dir, count, execute_once);
#endif
    } else {
#if PG_VERSION_NUM >= 180000
        standard_ExecutorRun(qd, dir, count);
#else
        standard_ExecutorRun(qd, dir, count, execute_once);
#endif
    }
    if (pgx_nim_exec_run_post != NULL) {
        pgx_nim_exec_run_post(qd, (int32)dir, count, execute_once);
    }
}

void pgx_install_executor_run_hook(PgxNimExecRunFn pre_fn, PgxNimExecRunFn post_fn) {
    pgx_nim_exec_run_pre = pre_fn;
    pgx_nim_exec_run_post = post_fn;
    if (ExecutorRun_hook != pgx_executor_run_trampoline) {
        pgx_prev_executor_run = ExecutorRun_hook;
        ExecutorRun_hook = pgx_executor_run_trampoline;
    }
}

void pgx_uninstall_executor_run_hook(void) {
    if (ExecutorRun_hook == pgx_executor_run_trampoline) {
        ExecutorRun_hook = pgx_prev_executor_run;
    }
    pgx_prev_executor_run = NULL;
    pgx_nim_exec_run_pre = NULL;
    pgx_nim_exec_run_post = NULL;
}

bool pgx_is_executor_run_hook_installed(void) {
    return ExecutorRun_hook == pgx_executor_run_trampoline;
}

/* --- ExecutorFinish --- */
void pgx_executor_finish_trampoline(QueryDesc *qd) {
    if (pgx_nim_exec_finish_pre != NULL) {
        pgx_nim_exec_finish_pre(qd);
    }
    if (pgx_prev_executor_finish != NULL) {
        pgx_prev_executor_finish(qd);
    } else {
        standard_ExecutorFinish(qd);
    }
    if (pgx_nim_exec_finish_post != NULL) {
        pgx_nim_exec_finish_post(qd);
    }
}

void pgx_install_executor_finish_hook(PgxNimExecQueryFn pre_fn, PgxNimExecQueryFn post_fn) {
    pgx_nim_exec_finish_pre = pre_fn;
    pgx_nim_exec_finish_post = post_fn;
    if (ExecutorFinish_hook != pgx_executor_finish_trampoline) {
        pgx_prev_executor_finish = ExecutorFinish_hook;
        ExecutorFinish_hook = pgx_executor_finish_trampoline;
    }
}

void pgx_uninstall_executor_finish_hook(void) {
    if (ExecutorFinish_hook == pgx_executor_finish_trampoline) {
        ExecutorFinish_hook = pgx_prev_executor_finish;
    }
    pgx_prev_executor_finish = NULL;
    pgx_nim_exec_finish_pre = NULL;
    pgx_nim_exec_finish_post = NULL;
}

bool pgx_is_executor_finish_hook_installed(void) {
    return ExecutorFinish_hook == pgx_executor_finish_trampoline;
}

/* --- ExecutorEnd --- */
void pgx_executor_end_trampoline(QueryDesc *qd) {
    if (pgx_nim_exec_end_pre != NULL) {
        pgx_nim_exec_end_pre(qd);
    }
    if (pgx_prev_executor_end != NULL) {
        pgx_prev_executor_end(qd);
    } else {
        standard_ExecutorEnd(qd);
    }
    if (pgx_nim_exec_end_post != NULL) {
        pgx_nim_exec_end_post(qd);
    }
}

void pgx_install_executor_end_hook(PgxNimExecQueryFn pre_fn, PgxNimExecQueryFn post_fn) {
    pgx_nim_exec_end_pre = pre_fn;
    pgx_nim_exec_end_post = post_fn;
    if (ExecutorEnd_hook != pgx_executor_end_trampoline) {
        pgx_prev_executor_end = ExecutorEnd_hook;
        ExecutorEnd_hook = pgx_executor_end_trampoline;
    }
}

void pgx_uninstall_executor_end_hook(void) {
    if (ExecutorEnd_hook == pgx_executor_end_trampoline) {
        ExecutorEnd_hook = pgx_prev_executor_end;
    }
    pgx_prev_executor_end = NULL;
    pgx_nim_exec_end_pre = NULL;
    pgx_nim_exec_end_post = NULL;
}

bool pgx_is_executor_end_hook_installed(void) {
    return ExecutorEnd_hook == pgx_executor_end_trampoline;
}

/* --- ProcessUtility (8 args across PG 14-18) --- */
void pgx_process_utility_trampoline(
    PlannedStmt *pstmt,
    const char *queryString,
    bool readOnlyTree,
    ProcessUtilityContext context,
    ParamListInfo params,
    QueryEnvironment *queryEnv,
    DestReceiver *dest,
    QueryCompletion *qc)
{
    if (pgx_nim_process_utility_pre != NULL) {
        pgx_nim_process_utility_pre(
            pstmt, (char *)queryString, readOnlyTree, (int32)context,
            (void *)params, (void *)queryEnv, (void *)dest, (void *)qc);
    }
    if (pgx_prev_process_utility != NULL) {
        pgx_prev_process_utility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
    } else {
        standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
    }
    if (pgx_nim_process_utility_post != NULL) {
        pgx_nim_process_utility_post(
            pstmt, (char *)queryString, readOnlyTree, (int32)context,
            (void *)params, (void *)queryEnv, (void *)dest, (void *)qc);
    }
}

void pgx_install_process_utility_hook(PgxNimProcessUtilityFn pre_fn, PgxNimProcessUtilityFn post_fn) {
    pgx_nim_process_utility_pre = pre_fn;
    pgx_nim_process_utility_post = post_fn;
    if (ProcessUtility_hook != pgx_process_utility_trampoline) {
        pgx_prev_process_utility = ProcessUtility_hook;
        ProcessUtility_hook = pgx_process_utility_trampoline;
    }
}

void pgx_uninstall_process_utility_hook(void) {
    if (ProcessUtility_hook == pgx_process_utility_trampoline) {
        ProcessUtility_hook = pgx_prev_process_utility;
    }
    pgx_prev_process_utility = NULL;
    pgx_nim_process_utility_pre = NULL;
    pgx_nim_process_utility_post = NULL;
}

bool pgx_is_process_utility_hook_installed(void) {
    return ProcessUtility_hook == pgx_process_utility_trampoline;
}

/* --- emit_log (with infinite-recursion guard) --- */
void pgx_emit_log_trampoline(ErrorData *edata) {
    if (pgx_in_emit_log) {
        if (pgx_prev_emit_log != NULL) {
            pgx_prev_emit_log(edata);
        }
        return;
    }
    pgx_in_emit_log = 1;
    if (pgx_nim_emit_log_pre != NULL) {
        pgx_nim_emit_log_pre(edata);
    }
    if (pgx_prev_emit_log != NULL) {
        pgx_prev_emit_log(edata);
    }
    if (pgx_nim_emit_log_post != NULL) {
        pgx_nim_emit_log_post(edata);
    }
    pgx_in_emit_log = 0;
}

void pgx_install_emit_log_hook(PgxNimEmitLogFn pre_fn, PgxNimEmitLogFn post_fn) {
    pgx_nim_emit_log_pre = pre_fn;
    pgx_nim_emit_log_post = post_fn;
    if (emit_log_hook != pgx_emit_log_trampoline) {
        pgx_prev_emit_log = emit_log_hook;
        emit_log_hook = pgx_emit_log_trampoline;
    }
}

void pgx_uninstall_emit_log_hook(void) {
    if (emit_log_hook == pgx_emit_log_trampoline) {
        emit_log_hook = pgx_prev_emit_log;
    }
    pgx_prev_emit_log = NULL;
    pgx_nim_emit_log_pre = NULL;
    pgx_nim_emit_log_post = NULL;
    pgx_in_emit_log = 0;
}

bool pgx_is_emit_log_hook_installed(void) {
    return emit_log_hook == pgx_emit_log_trampoline;
}

/* --- post_parse_analyze --- */
void pgx_post_parse_analyze_trampoline(ParseState *pstate, Query *query, JumbleState *jstate) {
    if (pgx_nim_post_parse_pre != NULL) {
        pgx_nim_post_parse_pre(pstate, query, jstate);
    }
    if (pgx_prev_post_parse_analyze != NULL) {
        pgx_prev_post_parse_analyze(pstate, query, jstate);
    }
    if (pgx_nim_post_parse_post != NULL) {
        pgx_nim_post_parse_post(pstate, query, jstate);
    }
}

void pgx_install_post_parse_analyze_hook(PgxNimPostParseFn pre_fn, PgxNimPostParseFn post_fn) {
    pgx_nim_post_parse_pre = pre_fn;
    pgx_nim_post_parse_post = post_fn;
    if (post_parse_analyze_hook != pgx_post_parse_analyze_trampoline) {
        pgx_prev_post_parse_analyze = post_parse_analyze_hook;
        post_parse_analyze_hook = pgx_post_parse_analyze_trampoline;
    }
}

void pgx_uninstall_post_parse_analyze_hook(void) {
    if (post_parse_analyze_hook == pgx_post_parse_analyze_trampoline) {
        post_parse_analyze_hook = pgx_prev_post_parse_analyze;
    }
    pgx_prev_post_parse_analyze = NULL;
    pgx_nim_post_parse_pre = NULL;
    pgx_nim_post_parse_post = NULL;
}

bool pgx_is_post_parse_analyze_hook_installed(void) {
    return post_parse_analyze_hook == pgx_post_parse_analyze_trampoline;
}
""".}

type
  HookPhase* = enum
    hpPre   ## Execute before chaining to prev_* / standard_*
    hpPost  ## Execute after prev_* / standard_* completes

  PgxHookSlot[T] = object
    cb*: T
    phase*: HookPhase

  PgxHookList[T] = object
    data*: ptr UncheckedArray[PgxHookSlot[T]]
    len*: int
    cap*: int

  PgxNimExecStartFn = proc(qd: QueryDescPtr, eflags: int32) {.cdecl.}
  PgxNimExecRunFn = proc(qd: QueryDescPtr, dir: int32, count: uint64, executeOnce: bool) {.cdecl.}
  PgxNimExecQueryFn = proc(qd: QueryDescPtr) {.cdecl.}
  PgxNimProcessUtilityFn = proc(
    pstmt: PlannedStmtPtr,
    queryString: cstring,
    readOnlyTree: bool,
    context: int32,
    params: pointer,
    queryEnv: pointer,
    dest: pointer,
    qc: pointer
  ) {.cdecl.}
  PgxNimEmitLogFn = proc(edata: ptr ErrorData) {.cdecl.}
  PgxNimPostParseFn = proc(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.}

{.push header: "pgx_hooks.h".}
proc pgxInstallExecutorStartHook(preFn, postFn: PgxNimExecStartFn) {.importc: "pgx_install_executor_start_hook".}
proc pgxUninstallExecutorStartHook() {.importc: "pgx_uninstall_executor_start_hook".}
proc pgxIsExecutorStartHookInstalled(): bool {.importc: "pgx_is_executor_start_hook_installed".}

proc pgxInstallExecutorRunHook(preFn, postFn: PgxNimExecRunFn) {.importc: "pgx_install_executor_run_hook".}
proc pgxUninstallExecutorRunHook() {.importc: "pgx_uninstall_executor_run_hook".}
proc pgxIsExecutorRunHookInstalled(): bool {.importc: "pgx_is_executor_run_hook_installed".}

proc pgxInstallExecutorFinishHook(preFn, postFn: PgxNimExecQueryFn) {.importc: "pgx_install_executor_finish_hook".}
proc pgxUninstallExecutorFinishHook() {.importc: "pgx_uninstall_executor_finish_hook".}
proc pgxIsExecutorFinishHookInstalled(): bool {.importc: "pgx_is_executor_finish_hook_installed".}

proc pgxInstallExecutorEndHook(preFn, postFn: PgxNimExecQueryFn) {.importc: "pgx_install_executor_end_hook".}
proc pgxUninstallExecutorEndHook() {.importc: "pgx_uninstall_executor_end_hook".}
proc pgxIsExecutorEndHookInstalled(): bool {.importc: "pgx_is_executor_end_hook_installed".}

proc pgxInstallProcessUtilityHook(preFn, postFn: PgxNimProcessUtilityFn) {.importc: "pgx_install_process_utility_hook".}
proc pgxUninstallProcessUtilityHook() {.importc: "pgx_uninstall_process_utility_hook".}
proc pgxIsProcessUtilityHookInstalled(): bool {.importc: "pgx_is_process_utility_hook_installed".}

proc pgxInstallEmitLogHook(preFn, postFn: PgxNimEmitLogFn) {.importc: "pgx_install_emit_log_hook".}
proc pgxUninstallEmitLogHook() {.importc: "pgx_uninstall_emit_log_hook".}
proc pgxIsEmitLogHookInstalled(): bool {.importc: "pgx_is_emit_log_hook_installed".}

proc pgxInstallPostParseAnalyzeHook(preFn, postFn: PgxNimPostParseFn) {.importc: "pgx_install_post_parse_analyze_hook".}
proc pgxUninstallPostParseAnalyzeHook() {.importc: "pgx_uninstall_post_parse_analyze_hook".}
proc pgxIsPostParseAnalyzeHookInstalled(): bool {.importc: "pgx_is_post_parse_analyze_hook_installed".}
{.pop.}

var
  gExecStartHooks   {.global.}: PgxHookList[ExecutorStartHook]
  gExecRunHooks     {.global.}: PgxHookList[ExecutorRunHook]
  gExecFinishHooks  {.global.}: PgxHookList[ExecutorFinishHook]
  gExecEndHooks     {.global.}: PgxHookList[ExecutorEndHook]
  gUtilityHooks     {.global.}: PgxHookList[ProcessUtilityHook]
  gEmitLogHooks     {.global.}: PgxHookList[EmitLogHook]
  gPostParseHooks   {.global.}: PgxHookList[PostParseHook]

proc addHook[T](list: var PgxHookList[T], cb: T, phase: HookPhase) =
  if cb == nil:
    raise newException(ValueError, "Hook callback cannot be nil")
  if list.len >= list.cap:
    let newCap = if list.cap == 0: 8 else: list.cap * 2
    let elemSize = sizeof(PgxHookSlot[T]).csize_t
    let newMem =
      if list.data == nil:
        real_calloc(newCap.csize_t, elemSize)
      else:
        real_realloc(list.data, newCap.csize_t * elemSize)
    if newMem == nil:
      raise newException(OutOfMemDefect, "Out of memory allocating hook registry storage")
    let newArr = cast[ptr UncheckedArray[PgxHookSlot[T]]](newMem)
    if newCap > list.cap:
      zeroMem(addr newArr[list.cap], (newCap - list.cap) * sizeof(PgxHookSlot[T]))
    list.data = newArr
    list.cap = newCap
  list.data[list.len] = PgxHookSlot[T](cb: cb, phase: phase)
  inc list.len

proc clearHooks[T](list: var PgxHookList[T]) =
  if list.data != nil:
    for i in 0 ..< list.len:
      reset(list.data[i])
    real_free(list.data)
    list.data = nil
  list.len = 0
  list.cap = 0

proc hasPhase[T](list: PgxHookList[T], phase: HookPhase): bool {.inline.} =
  for i in 0 ..< list.len:
    if list.data != nil and list.data[i].phase == phase:
      return true
  return false

template dispatchGuarded(body: untyped) =
  var pendingErr = false
  var errCode: cint = 0
  var errMsg: cstring = nil
  var errDetail: cstring = nil
  var errHint: cstring = nil
  try:
    body
  except Defect as e:
    prepareNimDefect(e, errCode, errMsg, errDetail, errHint)
    pendingErr = true
  except CatchableError as e:
    prepareNimError(e, errCode, errMsg, errDetail, errHint)
    pendingErr = true
  if pendingErr:
    pgxEreportFull(ERROR, errCode, errMsg, errDetail, errHint)

template runWithSavedFrame(stepFn: PgxGuardedFn, argPtr: pointer) =
  var pgxSaved = pgxSaveFrameState()
  pgxCallGuardedRethrowRaw(stepFn, argPtr, pgxOnCatchRestore, addr pgxSaved)
  reset(pgxSaved)

# -----------------------------------------------------------------------------
# Dispatchers (stackTrace: off so zero dead TFrame entries exist across siglongjmp)
# -----------------------------------------------------------------------------
{.push stackTrace: off.}

type
  ExecStartArgs = object
    qd: QueryDescPtr
    eflags: int32
    phase: HookPhase

proc execStartStep(p: pointer) {.cdecl.} =
  let a = cast[ptr ExecStartArgs](p)
  let info = ExecutorQueryInfo(raw: a.qd)
  let eflags = a.eflags.cint
  let phase = a.phase
  dispatchGuarded:
    let n = gExecStartHooks.len
    for i in 0 ..< n:
      if gExecStartHooks.data != nil and i < gExecStartHooks.len:
        if gExecStartHooks.data[i].phase == phase and gExecStartHooks.data[i].cb != nil:
          gExecStartHooks.data[i].cb(info, eflags)

proc dispatchExecStartPre(qd: QueryDescPtr, eflags: int32) {.cdecl.} =
  var args = ExecStartArgs(qd: qd, eflags: eflags, phase: hpPre)
  runWithSavedFrame(execStartStep, addr args)

proc dispatchExecStartPost(qd: QueryDescPtr, eflags: int32) {.cdecl.} =
  var args = ExecStartArgs(qd: qd, eflags: eflags, phase: hpPost)
  runWithSavedFrame(execStartStep, addr args)

type
  ExecRunArgs = object
    qd: QueryDescPtr
    dir: int32
    count: uint64
    executeOnce: bool
    phase: HookPhase

proc execRunStep(p: pointer) {.cdecl.} =
  let a = cast[ptr ExecRunArgs](p)
  let info = ExecutorQueryInfo(raw: a.qd)
  let dir = ScanDirection(a.dir)
  let count = a.count
  let executeOnce = a.executeOnce
  let phase = a.phase
  dispatchGuarded:
    let n = gExecRunHooks.len
    for i in 0 ..< n:
      if gExecRunHooks.data != nil and i < gExecRunHooks.len:
        if gExecRunHooks.data[i].phase == phase and gExecRunHooks.data[i].cb != nil:
          gExecRunHooks.data[i].cb(info, dir, count, executeOnce)

proc dispatchExecRunPre(qd: QueryDescPtr, dir: int32, count: uint64, executeOnce: bool) {.cdecl.} =
  var args = ExecRunArgs(qd: qd, dir: dir, count: count, executeOnce: executeOnce, phase: hpPre)
  runWithSavedFrame(execRunStep, addr args)

proc dispatchExecRunPost(qd: QueryDescPtr, dir: int32, count: uint64, executeOnce: bool) {.cdecl.} =
  var args = ExecRunArgs(qd: qd, dir: dir, count: count, executeOnce: executeOnce, phase: hpPost)
  runWithSavedFrame(execRunStep, addr args)

type
  ExecQueryArgs = object
    qd: QueryDescPtr
    phase: HookPhase

proc execFinishStep(p: pointer) {.cdecl.} =
  let a = cast[ptr ExecQueryArgs](p)
  let info = ExecutorQueryInfo(raw: a.qd)
  let phase = a.phase
  dispatchGuarded:
    let n = gExecFinishHooks.len
    for i in 0 ..< n:
      if gExecFinishHooks.data != nil and i < gExecFinishHooks.len:
        if gExecFinishHooks.data[i].phase == phase and gExecFinishHooks.data[i].cb != nil:
          gExecFinishHooks.data[i].cb(info)

proc dispatchExecFinishPre(qd: QueryDescPtr) {.cdecl.} =
  var args = ExecQueryArgs(qd: qd, phase: hpPre)
  runWithSavedFrame(execFinishStep, addr args)

proc dispatchExecFinishPost(qd: QueryDescPtr) {.cdecl.} =
  var args = ExecQueryArgs(qd: qd, phase: hpPost)
  runWithSavedFrame(execFinishStep, addr args)

proc execEndStep(p: pointer) {.cdecl.} =
  let a = cast[ptr ExecQueryArgs](p)
  let info = ExecutorQueryInfo(raw: a.qd)
  let phase = a.phase
  dispatchGuarded:
    let n = gExecEndHooks.len
    for i in 0 ..< n:
      if gExecEndHooks.data != nil and i < gExecEndHooks.len:
        if gExecEndHooks.data[i].phase == phase and gExecEndHooks.data[i].cb != nil:
          gExecEndHooks.data[i].cb(info)

proc dispatchExecEndPre(qd: QueryDescPtr) {.cdecl.} =
  var args = ExecQueryArgs(qd: qd, phase: hpPre)
  runWithSavedFrame(execEndStep, addr args)

proc dispatchExecEndPost(qd: QueryDescPtr) {.cdecl.} =
  var args = ExecQueryArgs(qd: qd, phase: hpPost)
  runWithSavedFrame(execEndStep, addr args)

type
  UtilityArgs = object
    info: UtilityStmtInfo
    phase: HookPhase

proc processUtilityStep(p: pointer) {.cdecl.} =
  let a = cast[ptr UtilityArgs](p)
  let info = a.info
  let phase = a.phase
  dispatchGuarded:
    let n = gUtilityHooks.len
    for i in 0 ..< n:
      if gUtilityHooks.data != nil and i < gUtilityHooks.len:
        if gUtilityHooks.data[i].phase == phase and gUtilityHooks.data[i].cb != nil:
          gUtilityHooks.data[i].cb(info)

proc dispatchProcessUtility(
  pstmt: PlannedStmtPtr,
  queryString: cstring,
  readOnlyTree: bool,
  context: int32,
  params: pointer,
  queryEnv: pointer,
  dest: pointer,
  qc: pointer,
  phase: HookPhase
) {.inline.} =
  var args = UtilityArgs(
    info: UtilityStmtInfo(
      rawPstmt: pstmt,
      queryStringPtr: queryString,
      readOnlyTree: readOnlyTree,
      context: ProcessUtilityContext(context),
      params: params,
      queryEnv: queryEnv,
      dest: dest,
      qc: qc
    ),
    phase: phase
  )
  runWithSavedFrame(processUtilityStep, addr args)

proc dispatchProcessUtilityPre(
  pstmt: PlannedStmtPtr,
  queryString: cstring,
  readOnlyTree: bool,
  context: int32,
  params: pointer,
  queryEnv: pointer,
  dest: pointer,
  qc: pointer
) {.cdecl.} =
  dispatchProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc, hpPre)

proc dispatchProcessUtilityPost(
  pstmt: PlannedStmtPtr,
  queryString: cstring,
  readOnlyTree: bool,
  context: int32,
  params: pointer,
  queryEnv: pointer,
  dest: pointer,
  qc: pointer
) {.cdecl.} =
  dispatchProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc, hpPost)

proc dispatchEmitLogPhase(edata: ptr ErrorData, phase: HookPhase) =
  try:
    let n = gEmitLogHooks.len
    for i in 0 ..< n:
      if gEmitLogHooks.data != nil and i < gEmitLogHooks.len:
        if gEmitLogHooks.data[i].phase == phase and gEmitLogHooks.data[i].cb != nil:
          gEmitLogHooks.data[i].cb(edata)
  except Defect:
    discard
  except CatchableError:
    discard

proc dispatchEmitLogPre(edata: ptr ErrorData) {.cdecl.} =
  dispatchEmitLogPhase(edata, hpPre)

proc dispatchEmitLogPost(edata: ptr ErrorData) {.cdecl.} =
  dispatchEmitLogPhase(edata, hpPost)

type
  PostParseArgs = object
    pstate: ptr ParseState
    query: ptr Query
    jstate: JumbleStatePtr
    phase: HookPhase

proc postParseStep(p: pointer) {.cdecl.} =
  let a = cast[ptr PostParseArgs](p)
  let pstate = a.pstate
  let query = a.query
  let jstate = a.jstate
  let phase = a.phase
  dispatchGuarded:
    let n = gPostParseHooks.len
    for i in 0 ..< n:
      if gPostParseHooks.data != nil and i < gPostParseHooks.len:
        if gPostParseHooks.data[i].phase == phase and gPostParseHooks.data[i].cb != nil:
          gPostParseHooks.data[i].cb(pstate, query, jstate)

proc dispatchPostParsePre(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.} =
  var args = PostParseArgs(pstate: pstate, query: query, jstate: jstate, phase: hpPre)
  runWithSavedFrame(postParseStep, addr args)

proc dispatchPostParsePost(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.} =
  var args = PostParseArgs(pstate: pstate, query: query, jstate: jstate, phase: hpPost)
  runWithSavedFrame(postParseStep, addr args)

{.pop.}

# -----------------------------------------------------------------------------
# Public Hook Registration API
# -----------------------------------------------------------------------------
proc registerExecutorStartHook*(cb: ExecutorStartHook, phase: HookPhase = hpPre) =
  ## Registers a composable ExecutorStart hook callback (safe across PG 14-18).
  gExecStartHooks.addHook(cb, phase)
  let preFn = if gExecStartHooks.hasPhase(hpPre): dispatchExecStartPre else: nil
  let postFn = if gExecStartHooks.hasPhase(hpPost): dispatchExecStartPost else: nil
  pgxInstallExecutorStartHook(preFn, postFn)

proc registerExecutorRunHook*(cb: ExecutorRunHook, phase: HookPhase = hpPre) =
  ## Registers a composable ExecutorRun hook callback (PG 18 3-arg & PG 14-17 4-arg safe).
  gExecRunHooks.addHook(cb, phase)
  let preFn = if gExecRunHooks.hasPhase(hpPre): dispatchExecRunPre else: nil
  let postFn = if gExecRunHooks.hasPhase(hpPost): dispatchExecRunPost else: nil
  pgxInstallExecutorRunHook(preFn, postFn)

proc registerExecutorFinishHook*(cb: ExecutorFinishHook, phase: HookPhase = hpPre) =
  ## Registers a composable ExecutorFinish hook callback.
  gExecFinishHooks.addHook(cb, phase)
  let preFn = if gExecFinishHooks.hasPhase(hpPre): dispatchExecFinishPre else: nil
  let postFn = if gExecFinishHooks.hasPhase(hpPost): dispatchExecFinishPost else: nil
  pgxInstallExecutorFinishHook(preFn, postFn)

proc registerExecutorEndHook*(cb: ExecutorEndHook, phase: HookPhase = hpPre) =
  ## Registers a composable ExecutorEnd hook callback.
  ## Defaults to hpPre because standard_ExecutorEnd frees QueryDesc->estate.
  gExecEndHooks.addHook(cb, phase)
  let preFn = if gExecEndHooks.hasPhase(hpPre): dispatchExecEndPre else: nil
  let postFn = if gExecEndHooks.hasPhase(hpPost): dispatchExecEndPost else: nil
  pgxInstallExecutorEndHook(preFn, postFn)

proc registerProcessUtilityHook*(cb: ProcessUtilityHook, phase: HookPhase = hpPre) =
  ## Registers a composable ProcessUtility_hook callback.
  gUtilityHooks.addHook(cb, phase)
  let preFn = if gUtilityHooks.hasPhase(hpPre): dispatchProcessUtilityPre else: nil
  let postFn = if gUtilityHooks.hasPhase(hpPost): dispatchProcessUtilityPost else: nil
  pgxInstallProcessUtilityHook(preFn, postFn)

proc registerEmitLogHook*(cb: EmitLogHook, phase: HookPhase = hpPre) =
  ## Registers a composable emit_log_hook callback (recursion-guarded, never errors).
  gEmitLogHooks.addHook(cb, phase)
  let preFn = if gEmitLogHooks.hasPhase(hpPre): dispatchEmitLogPre else: nil
  let postFn = if gEmitLogHooks.hasPhase(hpPost): dispatchEmitLogPost else: nil
  pgxInstallEmitLogHook(preFn, postFn)

proc registerPostParseHook*(cb: PostParseHook, phase: HookPhase = hpPre) =
  ## Registers a composable post_parse_analyze_hook callback.
  gPostParseHooks.addHook(cb, phase)
  let preFn = if gPostParseHooks.hasPhase(hpPre): dispatchPostParsePre else: nil
  let postFn = if gPostParseHooks.hasPhase(hpPost): dispatchPostParsePost else: nil
  pgxInstallPostParseAnalyzeHook(preFn, postFn)

# -----------------------------------------------------------------------------
# Introspection, Uninstall & Unit Test Reset Helpers
# -----------------------------------------------------------------------------
proc isExecutorStartHookInstalled*(): bool = pgxIsExecutorStartHookInstalled()
proc isExecutorRunHookInstalled*(): bool = pgxIsExecutorRunHookInstalled()
proc isExecutorFinishHookInstalled*(): bool = pgxIsExecutorFinishHookInstalled()
proc isExecutorEndHookInstalled*(): bool = pgxIsExecutorEndHookInstalled()
proc isProcessUtilityHookInstalled*(): bool = pgxIsProcessUtilityHookInstalled()
proc isEmitLogHookInstalled*(): bool = pgxIsEmitLogHookInstalled()
proc isPostParseHookInstalled*(): bool = pgxIsPostParseAnalyzeHookInstalled()

proc executorStartHookCount*(): int {.inline.} = gExecStartHooks.len
proc executorRunHookCount*(): int {.inline.} = gExecRunHooks.len
proc executorFinishHookCount*(): int {.inline.} = gExecFinishHooks.len
proc executorEndHookCount*(): int {.inline.} = gExecEndHooks.len
proc processUtilityHookCount*(): int {.inline.} = gUtilityHooks.len
proc emitLogHookCount*(): int {.inline.} = gEmitLogHooks.len
proc postParseHookCount*(): int {.inline.} = gPostParseHooks.len

proc uninstallExecutorStartHook*() =
  pgxUninstallExecutorStartHook()
  clearHooks(gExecStartHooks)

proc uninstallExecutorRunHook*() =
  pgxUninstallExecutorRunHook()
  clearHooks(gExecRunHooks)

proc uninstallExecutorFinishHook*() =
  pgxUninstallExecutorFinishHook()
  clearHooks(gExecFinishHooks)

proc uninstallExecutorEndHook*() =
  pgxUninstallExecutorEndHook()
  clearHooks(gExecEndHooks)

proc uninstallExecutorHooks*() =
  uninstallExecutorStartHook()
  uninstallExecutorRunHook()
  uninstallExecutorFinishHook()
  uninstallExecutorEndHook()

proc uninstallProcessUtilityHook*() =
  pgxUninstallProcessUtilityHook()
  clearHooks(gUtilityHooks)

proc uninstallEmitLogHook*() =
  pgxUninstallEmitLogHook()
  clearHooks(gEmitLogHooks)

proc uninstallPostParseHook*() =
  pgxUninstallPostParseAnalyzeHook()
  clearHooks(gPostParseHooks)

proc uninstallComposableHooks*() =
  ## Safely restores all installed PostgreSQL hook pointers and clears all registered callbacks.
  uninstallExecutorHooks()
  uninstallProcessUtilityHook()
  uninstallEmitLogHook()
  uninstallPostParseHook()

proc resetComposableHooks*() =
  ## Alias for uninstallComposableHooks(), intended for unit test teardown.
  uninstallComposableHooks()
