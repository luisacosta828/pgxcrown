## =============================================================================
## PostgreSQL Reporting, Error Handling & PG_TRY Exception Shield
## =============================================================================

import errcodes
export errcodes

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/elog.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"

#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) MemoryContext CurrentMemoryContext = (MemoryContext)0;
__attribute__((weak)) MemoryContext TopMemoryContext = (MemoryContext)0;
__attribute__((weak)) Oid pgx_active_fn_nsp = (Oid)0;
__attribute__((weak)) Oid get_func_namespace(Oid funcid) { (void)funcid; return (Oid)0; }
__attribute__((weak)) void check_stack_depth(void) {}
#else
Oid pgx_active_fn_nsp = (Oid)0;
#endif

void pgx_check_stack_depth(void) {
  check_stack_depth();
}

void pgx_ereport_full(int elevel, int sqlerrcode, const char *msg, const char *detail, const char *hint) {
  ereport(elevel, (
    (sqlerrcode != 0 ? errcode(sqlerrcode) : 0),
    errmsg("%s", msg ? msg : ""),
    (detail && detail[0] ? errdetail("%s", detail) : 0),
    (hint && hint[0] ? errhint("%s", hint) : 0)
  ));
}

typedef struct {
  int sqlerrcode;
  char *message;
  char *detail;
  char *hint;
  char *context;
} PgxCapturedError_C;

typedef void (*pgx_guarded_fn)(void *data);
typedef Datum (*pgx_v1_raw_fn)(PG_FUNCTION_ARGS);

void pgx_call_guarded_rethrow(pgx_guarded_fn fn, void *data, pgx_guarded_fn on_catch, void *catch_ctx) {
  PG_TRY();
  {
    fn(data);
  }
  PG_CATCH();
  {
    if (on_catch != NULL) {
      on_catch(catch_ctx);
    }
    PG_RE_THROW();
  }
  PG_END_TRY();
}

void pgx_call_v1_rethrow(void *fn_ptr, void *fcinfo_ptr, void *out_datum, pgx_guarded_fn on_catch, void *catch_ctx) {
  volatile Datum res = (Datum)0;
  volatile Oid prev_fn_nsp = pgx_active_fn_nsp;
  FunctionCallInfo fc = (FunctionCallInfo)fcinfo_ptr;
  pgx_v1_raw_fn fn = (pgx_v1_raw_fn)fn_ptr;
  if (fc != NULL && fc->flinfo != NULL && OidIsValid(fc->flinfo->fn_oid)) {
    pgx_active_fn_nsp = get_func_namespace(fc->flinfo->fn_oid);
  }
  PG_TRY();
  {
    res = fn(fc);
    pgx_active_fn_nsp = prev_fn_nsp;
  }
  PG_CATCH();
  {
    pgx_active_fn_nsp = prev_fn_nsp;
    if (on_catch != NULL) {
      on_catch(catch_ctx);
    }
    PG_RE_THROW();
  }
  PG_END_TRY();
  if (out_datum != NULL) {
    *(Datum *)out_datum = res;
  }
}

void *pgx_enter_top_memory_context(void) {
  if (TopMemoryContext != (MemoryContext)0) {
    return (void *)MemoryContextSwitchTo(TopMemoryContext);
  }
  return (void *)CurrentMemoryContext;
}

void pgx_leave_memory_context(void *old_ctx) {
  if (old_ctx != NULL) {
    MemoryContextSwitchTo((MemoryContext)old_ctx);
  } else {
    CurrentMemoryContext = (MemoryContext)0;
  }
}

bool pgx_call_guarded(pgx_guarded_fn fn, void *data, void *out_err_raw) {

  PgxCapturedError_C *out_err = (PgxCapturedError_C*)out_err_raw;
  if (out_err != NULL) {
    out_err->sqlerrcode = 0;
    out_err->message = NULL;
    out_err->detail = NULL;
    out_err->hint = NULL;
    out_err->context = NULL;
  }
  /* Never `return` from inside PG_TRY: it would skip PG_END_TRY() and leave
   * PG_exception_stack pointing at this (dead) stack frame, so a later
   * ereport(ERROR) in the same call would siglongjmp into garbage. */
  MemoryContext oldcontext = CurrentMemoryContext;
  volatile bool ok = false;
  PG_TRY();
  {
    fn(data);
    ok = true;
  }
  PG_CATCH();
  {
    if (oldcontext != (MemoryContext)0) {
      MemoryContextSwitchTo(oldcontext);
    } else {
      CurrentMemoryContext = oldcontext;
    }
    ErrorData *edata = CopyErrorData();
    FlushErrorState();
    if (out_err != NULL && edata != NULL) {
      out_err->sqlerrcode = edata->sqlerrcode;
      out_err->message = edata->message ? pstrdup(edata->message) : NULL;
      out_err->detail = edata->detail ? pstrdup(edata->detail) : NULL;
      out_err->hint = edata->hint ? pstrdup(edata->hint) : NULL;
      out_err->context = edata->context ? pstrdup(edata->context) : NULL;
    }
    if (edata != NULL) {
      FreeErrorData(edata);
    }
    ok = false;
  }
  PG_END_TRY();
  return ok;
}

static inline void pgx_free_captured_error(void *err_raw) {
  PgxCapturedError_C *err = (PgxCapturedError_C*)err_raw;
  if (err != NULL) {
    if (err->message) { pfree((void*)err->message); err->message = NULL; }
    if (err->detail) { pfree((void*)err->detail); err->detail = NULL; }
    if (err->hint) { pfree((void*)err->hint); err->hint = NULL; }
    if (err->context) { pfree((void*)err->context); err->context = NULL; }
  }
}
""".}

type
  PgxCapturedError* {.bycopy.} = object
    sqlerrcode*: cint
    message*: cstring
    detail*: cstring
    hint*: cstring
    context*: cstring

  PgxGuardedFn* = proc(data: pointer) {.cdecl.}

proc pgxEreportFullRaw(elevel: cint, sqlerrcode: cint, msg: cstring, detail: cstring, hint: cstring) {.importc: "pgx_ereport_full", nodecl.}
proc pgxCallGuardedRaw(fn: PgxGuardedFn, data: pointer, outErr: ptr PgxCapturedError): bool {.importc: "pgx_call_guarded", nodecl.}
proc pgxFreeCapturedErrorRaw(err: ptr PgxCapturedError) {.importc: "pgx_free_captured_error", nodecl.}

proc pgxCallGuardedRethrowRaw*(fn: PgxGuardedFn, data: pointer, onCatch: PgxGuardedFn, catchCtx: pointer) {.importc: "pgx_call_guarded_rethrow".}
proc pgxCallV1RethrowRaw*(fn: pointer, fcinfo: pointer, outDatum: pointer, onCatch: PgxGuardedFn, catchCtx: pointer) {.importc: "pgx_call_v1_rethrow".}
proc pgxEnterTopMemoryContextRaw*(): pointer {.importc: "pgx_enter_top_memory_context".}
proc pgxLeaveMemoryContextRaw*(oldCtx: pointer) {.importc: "pgx_leave_memory_context".}
proc pgxCheckStackDepthRaw() {.importc: "pgx_check_stack_depth", nodecl, cdecl, noSideEffect.}

proc checkStackDepth*() {.noSideEffect, gcsafe, raises: [], tags: [].} =
  ## Enforces PostgreSQL `max_stack_depth` guard (raises SQLSTATE 54001 on overflow).
  pgxCheckStackDepthRaw()

type PgxFrameState* = typeof(getFrameState())

proc pgxSaveFrameState*(): PgxFrameState {.stackTrace: off, inline, noSideEffect.} =
  {.cast(noSideEffect).}:
    result = getFrameState()

proc pgxRestoreFrameState*(state: PgxFrameState) {.stackTrace: off, inline, noSideEffect.} =
  {.cast(noSideEffect).}:
    setFrameState(state)

proc pgxOnCatchRestore*(p: pointer) {.cdecl, stackTrace: off, noSideEffect.} =
  {.cast(noSideEffect).}:
    let st = cast[ptr PgxFrameState](p)
    pgxRestoreFrameState(st[])
    reset(st[])

template pgxWithTopMemoryContext*(body: untyped): untyped =
  let pgxOldCtx = pgxEnterTopMemoryContextRaw()
  try:
    body
  finally:
    pgxLeaveMemoryContextRaw(pgxOldCtx)

template pgxRunVoidGuarded*(implProc: untyped): untyped =
  block:
    var pgxSaved = pgxSaveFrameState()
    proc pgxVoidStep(p: pointer) {.cdecl, stackTrace: off.} =
      implProc()
    pgxCallGuardedRethrowRaw(pgxVoidStep, nil, pgxOnCatchRestore, addr pgxSaved)
    reset(pgxSaved)

template pgxRunV1Guarded*(DatumT: typedesc, implProc: untyped): untyped =
  block:
    var pgxRes = default(DatumT)
    var pgxFcinfo: pointer = nil
    var pgxSaved = pgxSaveFrameState()
    {.cast(noSideEffect).}:
      {.cast(tags: []).}:
        {.cast(raises: []).}:
          {.emit: [pgxFcinfo, " = (void *)fcinfo;"].}
          pgxCallV1RethrowRaw(cast[pointer](implProc), pgxFcinfo, addr pgxRes, pgxOnCatchRestore, addr pgxSaved)
    reset(pgxSaved)
    pgxRes

proc pgxEreportFull*(elevel: cint, sqlerrcode: cint, msg: cstring, detail: cstring, hint: cstring) =
  pgxEreportFullRaw(elevel, sqlerrcode, msg, detail, hint)

proc pgxCallGuarded*(fn: PgxGuardedFn, data: pointer, outErr: ptr PgxCapturedError): bool =
  pgxCallGuardedRaw(fn, data, outErr)

proc pgxFreeCapturedError*(err: ptr PgxCapturedError) =
  pgxFreeCapturedErrorRaw(err)

# -----------------------------------------------------------------------------
# Reporting Procs
# -----------------------------------------------------------------------------
proc reportError*(code: cint, msg: string, detail: string = "", hint: string = "") =
  ## Reports an ERROR to PostgreSQL with specific SQLSTATE code, aborting current transaction
  pgxEreportFull(ERROR, code, cstring(msg), cstring(detail), cstring(hint))

proc reportError*(msg: string) =
  ## Reports an ERROR with default ERRCODE_INTERNAL_ERROR (XX000)
  reportError(ERRCODE_INTERNAL_ERROR, msg, "", "")

proc pgNotice*(msg: string, detail: string = "", hint: string = "") =
  ## Sends a NOTICE message to the client
  pgxEreportFull(NOTICE, 0, cstring(msg), cstring(detail), cstring(hint))

proc pgInfo*(msg: string, detail: string = "", hint: string = "") =
  ## Sends an INFO message to the client
  pgxEreportFull(INFO, 0, cstring(msg), cstring(detail), cstring(hint))

proc pgWarning*(msg: string, detail: string = "", hint: string = "") =
  ## Sends a WARNING message to the client
  pgxEreportFull(WARNING, 0, cstring(msg), cstring(detail), cstring(hint))

proc pgLog*(msg: string, detail: string = "", hint: string = "") =
  ## Emits a LOG entry to the PostgreSQL server log
  pgxEreportFull(LOG, 0, cstring(msg), cstring(detail), cstring(hint))

proc pgError*(code: cint, msg: string, detail: string = "", hint: string = "") {.noreturn.} =
  ## Directly raises a PostgreSQL ERROR aborting the transaction
  reportError(code, msg, detail, hint)

proc pgError*(sqlstate: string, msg: string, detail: string = "", hint: string = "") {.noreturn.} =
  ## Directly raises a PostgreSQL ERROR with 5-char SQLSTATE aborting the transaction
  reportError(makeSqlState(sqlstate), msg, detail, hint)

template report*(log_strategy, msg: typed) =
  ## Backward-compatible report template
  pgxEreportFull(log_strategy(), 0, cstring($msg), nil, nil)

# -----------------------------------------------------------------------------
# PG_TRY Guard for Safe PostgreSQL C & SPI Calls
# -----------------------------------------------------------------------------
type
  RawClosure* = object
    p*: pointer
    env*: pointer

  PgxRunnerData* = object
    rc*: RawClosure
    nimEx*: ref CatchableError
    nimDefect*: ref Defect

proc cdeclRunner(data: pointer) {.cdecl.} =
  let d = cast[ptr PgxRunnerData](data)
  let fn = cast[proc(env: pointer) {.nimcall.}](d.rc.p)
  try:
    fn(d.rc.env)
  except CatchableError as e:
    d.nimEx = e
  except Defect as e:
    d.nimDefect = e

template pgTry*(body: untyped): untyped =
  ## Executes code within PostgreSQL's PG_TRY / PG_CATCH block.
  ## If PostgreSQL raises an ereport(ERROR), it is safely intercepted,
  ## preventing stack corruption and raising a strongly-typed PostgresError in Nim.
  block:
    type ActionClosure = proc() {.closure.}
    var actionToRun: ActionClosure = proc() =
      body
    var rdata = PgxRunnerData(rc: cast[RawClosure](actionToRun), nimEx: nil, nimDefect: nil)
    var captured: PgxCapturedError
    var pgxTrySaved = pgxSaveFrameState()
    let ok = pgxCallGuarded(cdeclRunner, addr rdata, addr captured)
    if not ok:
      pgxRestoreFrameState(pgxTrySaved)
    reset(pgxTrySaved)
    if rdata.nimDefect != nil:
      raise rdata.nimDefect
    if rdata.nimEx != nil:
      raise rdata.nimEx
    if not ok:
      var err = newException(PostgresError, if captured.message != nil: $captured.message else: "PostgreSQL execution error")
      err.sqlerrcode = captured.sqlerrcode
      err.detail = if captured.detail != nil: $captured.detail else: ""
      err.hint = if captured.hint != nil: $captured.hint else: ""
      err.context = if captured.context != nil: $captured.context else: ""
      pgxFreeCapturedError(addr captured)
      raise err
    else:
      pgxFreeCapturedError(addr captured)

# -----------------------------------------------------------------------------
# Panic Shield Exception Dispatchers
# -----------------------------------------------------------------------------
proc pstrdup(x: cstring): cstring {.importc: "pstrdup", header: "postgres.h".}

proc prepareNimDefect*(e: ref Defect, outCode: var cint, outMsg, outDetail, outHint: var cstring) =
  ## Copies Defect diagnostic strings into PostgreSQL's CurrentMemoryContext via pstrdup
  ## so the Nim exception and all local RAII variables can be destroyed before siglongjmp.
  outDetail = nil
  outHint = nil
  if e of OverflowDefect:
    outCode = ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE
    outMsg = pstrdup(cstring("Extension Defect [OverflowDefect]: " & e.msg))
  elif e of DivByZeroDefect:
    outCode = ERRCODE_DIVISION_BY_ZERO
    outMsg = pstrdup(cstring("Extension Defect [DivByZeroDefect]: " & e.msg))
  elif e of IndexDefect:
    outCode = ERRCODE_ARRAY_SUBSCRIPT_ERROR
    outMsg = pstrdup(cstring("Extension Defect [IndexDefect]: " & e.msg))
  elif e of RangeDefect:
    outCode = ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE
    outMsg = pstrdup(cstring("Extension Defect [RangeDefect]: " & e.msg))
  elif e of NilAccessDefect:
    outCode = ERRCODE_NULL_VALUE_NOT_ALLOWED
    outMsg = pstrdup(cstring("Extension Defect [NilAccessDefect]: " & e.msg))
  elif e of OutOfMemDefect:
    outCode = ERRCODE_OUT_OF_MEMORY
    outMsg = pstrdup(cstring("Extension Defect [OutOfMemDefect]: " & e.msg))
  else:
    outCode = ERRCODE_INTERNAL_ERROR
    outMsg = pstrdup(cstring("Extension Defect [" & $e.name & "]: " & e.msg))

proc prepareNimError*(e: ref CatchableError, outCode: var cint, outMsg, outDetail, outHint: var cstring) =
  ## Copies CatchableError diagnostic strings into PostgreSQL's CurrentMemoryContext via pstrdup
  ## so the Nim exception and all local RAII variables can be destroyed before siglongjmp.
  outDetail = nil
  outHint = nil
  if e of PgError:
    let pe = cast[ref PgError](e)
    outCode = pe.sqlerrcode
    outMsg = pstrdup(cstring(pe.msg))
    if pe.detail.len > 0: outDetail = pstrdup(cstring(pe.detail))
    if pe.hint.len > 0: outHint = pstrdup(cstring(pe.hint))
  elif e of PostgresError:
    let pe = cast[ref PostgresError](e)
    outCode = pe.sqlerrcode
    outMsg = pstrdup(cstring(pe.msg))
    if pe.detail.len > 0: outDetail = pstrdup(cstring(pe.detail))
    if pe.hint.len > 0: outHint = pstrdup(cstring(pe.hint))
  elif e of ValueError:
    outCode = ERRCODE_INVALID_PARAMETER_VALUE
    outMsg = pstrdup(cstring("Extension Error [ValueError]: " & e.msg))
  elif e of KeyError:
    outCode = ERRCODE_NO_DATA_FOUND
    outMsg = pstrdup(cstring("Extension Error [KeyError]: " & e.msg))
  elif e of IOError:
    outCode = ERRCODE_IO_ERROR
    outMsg = pstrdup(cstring("Extension Error [IOError]: " & e.msg))
  elif e of OSError:
    outCode = ERRCODE_EXTERNAL_ROUTINE_EXCEPTION
    outMsg = pstrdup(cstring("Extension Error [OSError]: " & e.msg))
  else:
    outCode = ERRCODE_RAISE_EXCEPTION
    outMsg = pstrdup(cstring("Extension Error [" & $e.name & "]: " & e.msg))

proc reportNimDefect*(e: ref Defect) {.noreturn.} =
  ## Converts unhandled Nim Defects into appropriate PostgreSQL SQLSTATE errors
  var code: cint
  var msg, detail, hint: cstring
  prepareNimDefect(e, code, msg, detail, hint)
  pgxEreportFull(ERROR, code, msg, detail, hint)

proc reportNimError*(e: ref CatchableError) {.noreturn.} =
  ## Converts unhandled Nim CatchableErrors into appropriate PostgreSQL SQLSTATE errors
  var code: cint
  var msg, detail, hint: cstring
  prepareNimError(e, code, msg, detail, hint)
  pgxEreportFull(ERROR, code, msg, detail, hint)
