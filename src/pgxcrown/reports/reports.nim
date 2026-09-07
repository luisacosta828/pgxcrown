## =============================================================================
## PostgreSQL Reporting, Error Handling & PG_TRY Exception Shield
## =============================================================================

import errcodes
export errcodes

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "utils/elog.h"

static inline void pgx_ereport_full(int elevel, int sqlerrcode, const char *msg, const char *detail, const char *hint) {
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
} PgxCapturedError;

typedef void (*pgx_guarded_fn)(void *data);

static inline bool pgx_call_guarded(pgx_guarded_fn fn, void *data, PgxCapturedError *out_err) {
  if (out_err != NULL) {
    out_err->sqlerrcode = 0;
    out_err->message = NULL;
    out_err->detail = NULL;
    out_err->hint = NULL;
    out_err->context = NULL;
  }
  PG_TRY();
  {
    fn(data);
    return true;
  }
  PG_CATCH();
  {
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
    return false;
  }
  PG_END_TRY();
}
""".}

type
  PgxCapturedError* {.importc: "PgxCapturedError", nodecl.} = object
    sqlerrcode*: cint
    message*: cstring
    detail*: cstring
    hint*: cstring
    context*: cstring

  PgxGuardedFn* = proc(data: pointer) {.cdecl.}

proc pgxEreportFull(elevel: cint, sqlerrcode: cint, msg: cstring, detail: cstring, hint: cstring) {.importc: "pgx_ereport_full", nodecl.}
proc pgxCallGuarded*(fn: PgxGuardedFn, data: pointer, outErr: ptr PgxCapturedError): bool {.importc: "pgx_call_guarded", nodecl.}

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
  RawClosure = object
    p: pointer
    env: pointer

proc cdeclRunner(data: pointer) {.cdecl.} =
  let r = cast[ptr RawClosure](data)
  let fn = cast[proc(env: pointer) {.nimcall.}](r.p)
  fn(r.env)

template pgTry*(body: untyped): untyped =
  ## Executes code within PostgreSQL's PG_TRY / PG_CATCH block.
  ## If PostgreSQL raises an ereport(ERROR), it is safely intercepted,
  ## preventing stack corruption and raising a strongly-typed PostgresError in Nim.
  block:
    type ActionClosure = proc() {.closure.}
    var actionToRun: ActionClosure = proc() =
      body
    var rc = cast[RawClosure](actionToRun)
    var captured: PgxCapturedError
    let ok = pgxCallGuarded(cdeclRunner, addr rc, addr captured)
    if not ok:
      var err = newException(PostgresError, if captured.message != nil: $captured.message else: "PostgreSQL execution error")
      err.sqlerrcode = captured.sqlerrcode
      err.detail = if captured.detail != nil: $captured.detail else: ""
      err.hint = if captured.hint != nil: $captured.hint else: ""
      err.context = if captured.context != nil: $captured.context else: ""
      raise err

# -----------------------------------------------------------------------------
# Panic Shield Exception Dispatchers
# -----------------------------------------------------------------------------
proc reportNimDefect*(e: ref Defect) {.noreturn.} =
  ## Converts unhandled Nim Defects into appropriate PostgreSQL SQLSTATE errors
  if e of OverflowDefect:
    reportError(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE, "Extension Defect [OverflowDefect]: " & e.msg)
  elif e of DivByZeroDefect:
    reportError(ERRCODE_DIVISION_BY_ZERO, "Extension Defect [DivByZeroDefect]: " & e.msg)
  elif e of IndexDefect:
    reportError(ERRCODE_ARRAY_SUBSCRIPT_ERROR, "Extension Defect [IndexDefect]: " & e.msg)
  elif e of RangeDefect:
    reportError(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE, "Extension Defect [RangeDefect]: " & e.msg)
  elif e of NilAccessDefect:
    reportError(ERRCODE_NULL_VALUE_NOT_ALLOWED, "Extension Defect [NilAccessDefect]: " & e.msg)
  elif e of OutOfMemDefect:
    reportError(ERRCODE_OUT_OF_MEMORY, "Extension Defect [OutOfMemDefect]: " & e.msg)
  else:
    reportError(ERRCODE_INTERNAL_ERROR, "Extension Defect [" & $e.name & "]: " & e.msg)

proc reportNimError*(e: ref CatchableError) {.noreturn.} =
  ## Converts unhandled Nim CatchableErrors into appropriate PostgreSQL SQLSTATE errors
  if e of PgError:
    let pe = cast[ref PgError](e)
    reportError(pe.sqlerrcode, pe.msg, pe.detail, pe.hint)
  elif e of PostgresError:
    let pe = cast[ref PostgresError](e)
    reportError(pe.sqlerrcode, pe.msg, pe.detail, pe.hint)
  elif e of ValueError:
    reportError(ERRCODE_INVALID_PARAMETER_VALUE, "Extension Error [ValueError]: " & e.msg)
  elif e of KeyError:
    reportError(ERRCODE_NO_DATA_FOUND, "Extension Error [KeyError]: " & e.msg)
  elif e of IOError:
    reportError(ERRCODE_IO_ERROR, "Extension Error [IOError]: " & e.msg)
  elif e of OSError:
    reportError(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION, "Extension Error [OSError]: " & e.msg)
  else:
    reportError(ERRCODE_RAISE_EXCEPTION, "Extension Error [" & $e.name & "]: " & e.msg)
