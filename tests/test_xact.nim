import std/strutils

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
  " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql") &
  " -include postgres.h".}

import std/unittest
import ../src/pgxcrown

{.emit: """
#include "postgres.h"
#include "access/xact.h"
#include "utils/elog.h"
#include "utils/palloc.h"
#include "pgx_xact.h"
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

/* Mock Xact / SubXact registration state */
static XactCallback mockRegisteredXactCb = NULL;
static void *mockRegisteredXactArg = NULL;
static int mockRegisterXactCount = 0;

static SubXactCallback mockRegisteredSubXactCb = NULL;
static void *mockRegisteredSubXactArg = NULL;
static int mockRegisterSubXactCount = 0;

static SubTransactionId mockCurrentSubId = (SubTransactionId)1;

void RegisterXactCallback(XactCallback callback, void *arg) {
    mockRegisteredXactCb = callback;
    mockRegisteredXactArg = arg;
    mockRegisterXactCount++;
}

void UnregisterXactCallback(XactCallback callback, void *arg) {
    if (mockRegisteredXactCb == callback && mockRegisteredXactArg == arg) {
        mockRegisteredXactCb = NULL;
        mockRegisteredXactArg = NULL;
    }
}

void RegisterSubXactCallback(SubXactCallback callback, void *arg) {
    mockRegisteredSubXactCb = callback;
    mockRegisteredSubXactArg = arg;
    mockRegisterSubXactCount++;
}

void UnregisterSubXactCallback(SubXactCallback callback, void *arg) {
    if (mockRegisteredSubXactCb == callback && mockRegisteredSubXactArg == arg) {
        mockRegisteredSubXactCb = NULL;
        mockRegisteredSubXactArg = NULL;
    }
}

SubTransactionId GetCurrentSubTransactionId(void) {
    return mockCurrentSubId;
}

/* Mock Error / Warning / PG_TRY state */
static int mockWarnCount = 0;
static int mockErrorCount = 0;
static int mockCaughtErrorCount = 0;
static int mockCurElevel = 0;
static int mockCurSqlErrCode = 0;
static char mockCurMsg[512] = {0};
static char mockCurDetail[512] = {0};
static char mockCurHint[512] = {0};

static char mockLastWarnMsg[512] = {0};
static int mockLastErrorCode = 0;
static char mockLastErrorMsg[512] = {0};
static char mockLastErrorDetail[512] = {0};
static char mockLastErrorHint[512] = {0};
static ErrorData mockActiveErrorData;

bool errstart(int elevel, const char *domain) {
    (void)domain;
    mockCurElevel = elevel;
    mockCurSqlErrCode = 0;
    mockCurMsg[0] = '\0';
    mockCurDetail[0] = '\0';
    mockCurHint[0] = '\0';
    return true;
}

bool errstart_cold(int elevel, const char *domain) {
    return errstart(elevel, domain);
}

int errcode(int sqlerrcode) {
    mockCurSqlErrCode = sqlerrcode;
    return 0;
}

int errmsg(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockCurMsg, sizeof(mockCurMsg), fmt ? fmt : "", args);
    va_end(args);
    return 0;
}

int errdetail(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockCurDetail, sizeof(mockCurDetail), fmt ? fmt : "", args);
    va_end(args);
    return 0;
}

int errhint(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockCurHint, sizeof(mockCurHint), fmt ? fmt : "", args);
    va_end(args);
    return 0;
}

void errfinish(const char *filename, int lineno, const char *funcname) {
    (void)filename; (void)lineno; (void)funcname;
    if (mockCurElevel == WARNING) {
        mockWarnCount++;
        snprintf(mockLastWarnMsg, sizeof(mockLastWarnMsg), "%s", mockCurMsg);
    } else if (mockCurElevel >= ERROR) {
        if (PG_exception_stack != NULL) {
            mockCaughtErrorCount++;
            memset(&mockActiveErrorData, 0, sizeof(mockActiveErrorData));
            mockActiveErrorData.elevel = mockCurElevel;
            mockActiveErrorData.sqlerrcode = mockCurSqlErrCode;
            mockActiveErrorData.message = strdup(mockCurMsg);
            mockActiveErrorData.detail = mockCurDetail[0] ? strdup(mockCurDetail) : NULL;
            mockActiveErrorData.hint = mockCurHint[0] ? strdup(mockCurHint) : NULL;
            siglongjmp(*PG_exception_stack, 1);
        } else {
            mockErrorCount++;
            mockLastErrorCode = mockCurSqlErrCode;
            snprintf(mockLastErrorMsg, sizeof(mockLastErrorMsg), "%s", mockCurMsg);
            snprintf(mockLastErrorDetail, sizeof(mockLastErrorDetail), "%s", mockCurDetail);
            snprintf(mockLastErrorHint, sizeof(mockLastErrorHint), "%s", mockCurHint);
        }
    }
}

ErrorData *CopyErrorData(void) {
    ErrorData *copy = (ErrorData *)calloc(1, sizeof(ErrorData));
    if (copy) {
        copy->elevel = mockActiveErrorData.elevel;
        copy->sqlerrcode = mockActiveErrorData.sqlerrcode;
        copy->message = mockActiveErrorData.message ? strdup(mockActiveErrorData.message) : NULL;
        copy->detail = mockActiveErrorData.detail ? strdup(mockActiveErrorData.detail) : NULL;
        copy->hint = mockActiveErrorData.hint ? strdup(mockActiveErrorData.hint) : NULL;
    }
    return copy;
}

void FlushErrorState(void) {
    if (mockActiveErrorData.message) { free(mockActiveErrorData.message); mockActiveErrorData.message = NULL; }
    if (mockActiveErrorData.detail) { free(mockActiveErrorData.detail); mockActiveErrorData.detail = NULL; }
    if (mockActiveErrorData.hint) { free(mockActiveErrorData.hint); mockActiveErrorData.hint = NULL; }
}

void FreeErrorData(ErrorData *edata) {
    if (!edata) return;
    if (edata->message) free(edata->message);
    if (edata->detail) free(edata->detail);
    if (edata->hint) free(edata->hint);
    free(edata);
}

void pg_re_throw(void) {
    if (PG_exception_stack != NULL) {
        siglongjmp(*PG_exception_stack, 1);
    }
    abort();
}

char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void *palloc(Size size) { return malloc(size); }
void pfree(void *ptr) { if (ptr) free(ptr); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size); }

/* Test inspection & trigger helpers */
static int pgx_xact_abi_matches(void) {
    return (XACT_EVENT_COMMIT == 0 &&
            XACT_EVENT_PARALLEL_COMMIT == 1 &&
            XACT_EVENT_ABORT == 2 &&
            XACT_EVENT_PARALLEL_ABORT == 3 &&
            XACT_EVENT_PREPARE == 4 &&
            XACT_EVENT_PRE_COMMIT == 5 &&
            XACT_EVENT_PARALLEL_PRE_COMMIT == 6 &&
            XACT_EVENT_PRE_PREPARE == 7 &&
            SUBXACT_EVENT_START_SUB == 0 &&
            SUBXACT_EVENT_COMMIT_SUB == 1 &&
            SUBXACT_EVENT_ABORT_SUB == 2 &&
            SUBXACT_EVENT_PRE_COMMIT_SUB == 3) ? 1 : 0;
}

static void pgx_fire_mock_xact(int event) {
    if (mockRegisteredXactCb != NULL) {
        mockRegisteredXactCb((XactEvent)event, mockRegisteredXactArg);
    }
}

static void pgx_fire_mock_subxact(int event, unsigned int mySubid, unsigned int parentSubid) {
    if (mockRegisteredSubXactCb != NULL) {
        mockRegisteredSubXactCb((SubXactEvent)event, (SubTransactionId)mySubid, (SubTransactionId)parentSubid, mockRegisteredSubXactArg);
    }
}

static void pgx_reset_xact_mocks(void) {
    mockWarnCount = 0;
    mockErrorCount = 0;
    mockCaughtErrorCount = 0;
    mockLastWarnMsg[0] = '\0';
    mockLastErrorCode = 0;
    mockLastErrorMsg[0] = '\0';
    mockLastErrorDetail[0] = '\0';
    mockLastErrorHint[0] = '\0';
    FlushErrorState();
}

static void pgx_reset_registration_mocks(void) {
    pgx_xact_registered = 0;
    pgx_subxact_registered = 0;
    mockRegisteredXactCb = NULL;
    mockRegisteredXactArg = NULL;
    mockRegisterXactCount = 0;
    mockRegisteredSubXactCb = NULL;
    mockRegisteredSubXactArg = NULL;
    mockRegisterSubXactCount = 0;
}
""".}

proc pgxXactAbiMatches(): cint {.importc: "pgx_xact_abi_matches", nodecl.}
proc pgxFireMockXact(ev: cint) {.importc: "pgx_fire_mock_xact", nodecl.}
proc pgxFireMockSubXact(ev: cint, myId: cuint, parentId: cuint) {.importc: "pgx_fire_mock_subxact", nodecl.}
proc pgxResetXactMocks() {.importc: "pgx_reset_xact_mocks", nodecl.}
proc pgxResetRegMocks() {.importc: "pgx_reset_registration_mocks", nodecl.}
proc pgxEnsureXactRegDirect() {.importc: "pgx_ensure_xact_registered", nodecl.}
proc pgxEnsureSubXactRegDirect() {.importc: "pgx_ensure_subxact_registered", nodecl.}
proc pgxTriggerRawEreportError(msg: cstring) {.importc: "pgx_trigger_raw_err", nodecl.}

{.emit: """
static void pgx_trigger_raw_err(const char *msg) {
    ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("%s", msg)));
}
""".}

var
  mockRegisterXactCount {.importc: "mockRegisterXactCount", nodecl.}: cint
  mockRegisterSubXactCount {.importc: "mockRegisterSubXactCount", nodecl.}: cint
  mockCurrentSubId {.importc: "mockCurrentSubId", nodecl.}: uint32
  mockWarnCount {.importc: "mockWarnCount", nodecl.}: cint
  mockErrorCount {.importc: "mockErrorCount", nodecl.}: cint
  mockCaughtErrorCount {.importc: "mockCaughtErrorCount", nodecl.}: cint
  mockLastErrorCode {.importc: "mockLastErrorCode", nodecl.}: cint
  mockLastWarnMsg {.importc: "mockLastWarnMsg", nodecl.}: array[512, char]
  mockLastErrorMsg {.importc: "mockLastErrorMsg", nodecl.}: array[512, char]
  mockLastErrorDetail {.importc: "mockLastErrorDetail", nodecl.}: array[512, char]
  mockLastErrorHint {.importc: "mockLastErrorHint", nodecl.}: array[512, char]

proc cBufStr(a: openArray[char]): string =
  $cast[cstring](unsafeAddr a[0])

proc testEffectSafety(): tuple[valid: bool, removed: bool] {.forbids: [IOEffect, TimeEffect].} =
  var hits = 0
  var h: XactHandle
  pgxWithLibcAlloc:
    h = onCommit(proc() = inc hits)
  let hSub = onSubXactCommit(proc() = inc hits)
  let ok1 = h.isValid and hSub.isValid
  let ok2 = unregisterXactCallback(h) and unregisterSubXactCallback(hSub)
  (ok1, ok2)

suite "Pgxcrown - Transaction & Subtransaction Callbacks (xact.nim)":

  setup:
    clearXactCallbacks()
    pgxResetXactMocks()

  teardown:
    clearXactCallbacks()
    pgxResetXactMocks()
    CurrentMemoryContext = nil

  test "C-ABI enum ordinals & sizes match PG access/xact.h":
    check pgxXactAbiMatches() == 1
    check sizeof(XactEvent) == sizeof(cint)
    check sizeof(SubXactEvent) == sizeof(cint)
    check sizeof(SubTransactionId) == sizeof(cuint)
    check ord(xeCommit) == 0
    check ord(xeParallelCommit) == 1
    check ord(xeAbort) == 2
    check ord(xeParallelAbort) == 3
    check ord(xePrepare) == 4
    check ord(xePreCommit) == 5
    check ord(xeParallelPreCommit) == 6
    check ord(xePrePrepare) == 7
    check ord(sxeStartSub) == 0
    check ord(sxeCommitSub) == 1
    check ord(sxeAbortSub) == 2
    check ord(sxePreCommitSub) == 3

  test "Event errorability classification":
    for ev in low(XactEvent) .. high(XactEvent):
      if ev in {xePreCommit, xeParallelPreCommit, xePrePrepare}:
        check isErrorableXactEvent(ev) == true
      else:
        check isErrorableXactEvent(ev) == false
    for ev in low(SubXactEvent) .. high(SubXactEvent):
      if ev == sxePreCommitSub:
        check isErrorableSubXactEvent(ev) == true
      else:
        check isErrorableSubXactEvent(ev) == false

  test "Idempotent singleton C registration across repeated calls":
    pgxResetRegMocks()
    check mockRegisterXactCount == 0
    check mockRegisterSubXactCount == 0

    let h1 = registerXactCallback(proc(ev: XactEvent) = discard)
    let h2 = registerXactCallback(proc(ev: XactEvent) = discard)
    pgxEnsureXactRegDirect()
    check h1 != h2
    check mockRegisterXactCount == 1
    check xactCallbackCount() == 2

    let s1 = registerSubXactCallback(proc(ev: SubXactEvent, a, b: SubTransactionId) = discard)
    let s2 = registerSubXactCallback(proc(ev: SubXactEvent, a, b: SubTransactionId) = discard)
    pgxEnsureSubXactRegDirect()
    check s1 != s2
    check mockRegisterSubXactCount == 1
    check subXactCallbackCount() == 2

  test "Full XactEvent and SubXactEvent dispatch & FIFO ordering":
    var log: seq[string] = @[]
    discard registerXactCallback(proc(ev: XactEvent) =
      log.add("A:" & $ev)
    )
    discard registerXactCallback(proc(ev: XactEvent) =
      log.add("B:" & $ev)
    )
    for ev in low(XactEvent) .. high(XactEvent):
      pgxFireMockXact(cint(ord(ev)))
    check log.len == 16
    check log[0] == "A:xeCommit"
    check log[1] == "B:xeCommit"
    check log[14] == "A:xePrePrepare"
    check log[15] == "B:xePrePrepare"

    var subLog: seq[string] = @[]
    discard registerSubXactCallback(proc(ev: SubXactEvent, myId, parentId: SubTransactionId) =
      subLog.add($ev & ":" & $myId & "->" & $parentId)
    )
    pgxFireMockSubXact(cint(ord(sxeStartSub)), 2'u32, 1'u32)
    pgxFireMockSubXact(cint(ord(sxePreCommitSub)), 2'u32, 1'u32)
    pgxFireMockSubXact(cint(ord(sxeCommitSub)), 2'u32, 1'u32)
    pgxFireMockSubXact(cint(ord(sxeAbortSub)), 3'u32, 1'u32)
    check subLog == @[
      "sxeStartSub:2->1",
      "sxePreCommitSub:2->1",
      "sxeCommitSub:2->1",
      "sxeAbortSub:3->1"
    ]

  test "Convenience helpers: onCommit, onAbort, onPreCommit, onSubXactCommit, onSubXactAbort":
    var events: seq[string] = @[]
    let hCommit = onCommit(proc() = events.add("commit"))
    let hCommitPar = onCommit(proc() = events.add("commit_par"), includeParallel = true)
    let hAbort = onAbort(proc() = events.add("abort"))
    let hAbortPar = onAbort(proc() = events.add("abort_par"), includeParallel = true)
    let hPre = onPreCommit(proc() = events.add("pre_commit"))

    pgxFireMockXact(cint(ord(xePreCommit)))
    pgxFireMockXact(cint(ord(xeCommit)))
    pgxFireMockXact(cint(ord(xeParallelCommit)))
    pgxFireMockXact(cint(ord(xeAbort)))
    pgxFireMockXact(cint(ord(xeParallelAbort)))

    check events == @[
      "pre_commit",
      "commit", "commit_par",
      "commit_par",
      "abort", "abort_par",
      "abort_par"
    ]

    check unregisterXactCallback(hCommit) == true
    check unregisterXactCallback(hCommit) == false
    check unregisterXactCallback(InvalidXactHandle) == false
    check unregisterXactCallback(hCommitPar) == true
    check unregisterXactCallback(hAbort) == true
    check unregisterXactCallback(hAbortPar) == true
    check unregisterXactCallback(hPre) == true
    check xactCallbackCount() == 0

    var subEvents: seq[string] = @[]
    let hs1 = onSubXactCommit(proc(myId, parentId: SubTransactionId) =
      subEvents.add("sub_commit:" & $myId & ":" & $parentId)
    )
    let hs2 = onSubXactCommit(proc() = subEvents.add("sub_commit_0"))
    let hs3 = onSubXactAbort(proc(myId, parentId: SubTransactionId) =
      subEvents.add("sub_abort:" & $myId & ":" & $parentId)
    )
    let hs4 = onSubXactAbort(proc() = subEvents.add("sub_abort_0"))

    pgxFireMockSubXact(cint(ord(sxeCommitSub)), 4'u32, 2'u32)
    pgxFireMockSubXact(cint(ord(sxeAbortSub)), 5'u32, 2'u32)
    check subEvents == @[
      "sub_commit:4:2", "sub_commit_0",
      "sub_abort:5:2", "sub_abort_0"
    ]
    check unregisterSubXactCallback(hs1) == true
    check unregisterSubXactCallback(hs1) == false
    check unregisterSubXactCallback(InvalidSubXactHandle) == false
    check unregisterSubXactCallback(hs2) == true
    check unregisterSubXactCallback(hs3) == true
    check unregisterSubXactCallback(hs4) == true
    check subXactCallbackCount() == 0

  test "One-shot helpers auto-expire on match or opposite transaction termination":
    var fired = 0
    discard onCommit((proc() = inc fired), once = true)
    pgxFireMockXact(cint(ord(xePreCommit)))
    check xactCallbackCount() == 1
    pgxFireMockXact(cint(ord(xeCommit)))
    check fired == 1
    check xactCallbackCount() == 0

    # One-shot onCommit expires quietly if transaction aborts instead
    discard onCommit((proc() = inc fired), once = true)
    check xactCallbackCount() == 1
    pgxFireMockXact(cint(ord(xeAbort)))
    check fired == 1
    check xactCallbackCount() == 0

    # One-shot onAbort expires quietly if transaction commits instead
    var abortFired = 0
    discard onAbort((proc() = inc abortFired), once = true)
    pgxFireMockXact(cint(ord(xeCommit)))
    check abortFired == 0
    check xactCallbackCount() == 0

  test "Re-entrant unregistration & registration during callback iteration":
    var hSelf = InvalidXactHandle
    var hVictim = InvalidXactHandle
    var trace: seq[string] = @[]

    hSelf = registerXactCallback(proc(ev: XactEvent) =
      trace.add("self:" & $ev)
      check unregisterXactCallback(hSelf) == true
      check unregisterXactCallback(hVictim) == true
      # Register a new callback during iteration; must NOT fire on this event, MUST fire on next
      discard registerXactCallback(proc(ev2: XactEvent) =
        trace.add("late:" & $ev2)
      )
    )
    hVictim = registerXactCallback(proc(ev: XactEvent) =
      trace.add("victim_should_not_run")
    )
    discard registerXactCallback(proc(ev: XactEvent) =
      trace.add("survivor:" & $ev)
    )

    pgxFireMockXact(cint(ord(xePreCommit)))
    check trace == @["self:xePreCommit", "survivor:xePreCommit"]
    check xactCallbackCount() == 2

    pgxFireMockXact(cint(ord(xeCommit)))
    check trace == @[
      "self:xePreCommit", "survivor:xePreCommit",
      "survivor:xeCommit", "late:xeCommit"
    ]

  test "Anti-PANIC shield during non-errorable phases converts errors & defects to WARNING":
    var tailRan = 0
    discard registerXactCallback(proc(ev: XactEvent) =
      if ev == xeAbort:
        raise newException(ValueError, "boom in abort")
      elif ev == xeCommit:
        raise newException(IndexDefect, "oob in commit")
      elif ev == xePrepare:
        pgxTriggerRawEreportError("raw ereport in prepare")
      elif ev == xeParallelAbort:
        raise newException(IOError, "io in parallel abort")
      elif ev == xeParallelCommit:
        raise newException(OverflowDefect, "ovf in parallel commit")
    )
    discard registerXactCallback(proc(ev: XactEvent) =
      inc tailRan
    )

    for ev in [xeAbort, xeCommit, xePrepare, xeParallelAbort, xeParallelCommit]:
      pgxFireMockXact(cint(ord(ev)))

    check mockErrorCount == 0
    check mockCaughtErrorCount == 1
    check mockWarnCount == 5
    check tailRan == 5

    # SubXact non-errorable phases
    var subTailRan = 0
    discard registerSubXactCallback(proc(ev: SubXactEvent, a, b: SubTransactionId) =
      if ev == sxeCommitSub:
        raise newException(ValueError, "boom in commit_sub")
      elif ev == sxeAbortSub:
        pgxTriggerRawEreportError("raw ereport in abort_sub")
      elif ev == sxeStartSub:
        raise newException(RangeDefect, "range in start_sub")
    )
    discard registerSubXactCallback(proc(ev: SubXactEvent, a, b: SubTransactionId) =
      inc subTailRan
    )

    pgxFireMockSubXact(cint(ord(sxeStartSub)), 2'u32, 1'u32)
    pgxFireMockSubXact(cint(ord(sxeCommitSub)), 2'u32, 1'u32)
    pgxFireMockSubXact(cint(ord(sxeAbortSub)), 3'u32, 1'u32)
    check mockErrorCount == 0
    check mockCaughtErrorCount == 2
    check mockWarnCount == 8
    check subTailRan == 3

  test "Errorable phases translate PgError, CatchableError, Defect, and raw PG ERROR cleanly":
    # 1) PgError preserves SQLSTATE, message, detail, hint
    var h = registerXactCallback(proc(ev: XactEvent) =
      if ev == xePreCommit:
        raisePgError("22023", "precommit validation failed", detail = "d1", hint = "h1")
    )
    pgxFireMockXact(cint(ord(xePreCommit)))
    check mockErrorCount == 1
    check unpackSqlState(mockLastErrorCode) == "22023"
    check cBufStr(mockLastErrorMsg) == "precommit validation failed"
    check cBufStr(mockLastErrorDetail) == "d1"
    check cBufStr(mockLastErrorHint) == "h1"
    check unregisterXactCallback(h)

    # 2) Defect translates cleanly
    pgxResetXactMocks()
    h = registerXactCallback(proc(ev: XactEvent) =
      if ev == xeParallelPreCommit:
        raise newException(DivByZeroDefect, "zero div in precommit")
    )
    pgxFireMockXact(cint(ord(xeParallelPreCommit)))
    check mockErrorCount == 1
    check unpackSqlState(mockLastErrorCode) == "22012"
    check "DivByZeroDefect" in cBufStr(mockLastErrorMsg)
    check unregisterXactCallback(h)

    # 3) Raw PG ereport(ERROR) intercepted via PG_TRY and re-emitted cleanly
    pgxResetXactMocks()
    h = registerXactCallback(proc(ev: XactEvent) =
      if ev == xePrePrepare:
        pgxTriggerRawEreportError("raw pre-prepare failure")
    )
    pgxFireMockXact(cint(ord(xePrePrepare)))
    check mockCaughtErrorCount == 1
    check mockErrorCount == 1
    check cBufStr(mockLastErrorMsg) == "raw pre-prepare failure"
    check unregisterXactCallback(h)

    # 4) SubXact pre-commit failure
    pgxResetXactMocks()
    let hs = registerSubXactCallback(proc(ev: SubXactEvent, a, b: SubTransactionId) =
      if ev == sxePreCommitSub:
        raise newException(ValueError, "subxact validation failed")
    )
    pgxFireMockSubXact(cint(ord(sxePreCommitSub)), 7'u32, 1'u32)
    check mockErrorCount == 1
    check "subxact validation failed" in cBufStr(mockLastErrorMsg)
    check unregisterSubXactCallback(hs)

  test "pgxWithLibcAlloc toggles allocator mode & survives MemoryContextReset":
    var fakeCtx: int = 42
    CurrentMemoryContext = cast[MemoryContext](addr fakeCtx)
    check isPostgresAllocActive() == true

    pgxWithLibcAlloc:
      check isPostgresAllocActive() == false
      try:
        pgxWithLibcAlloc:
          check isPostgresAllocActive() == false
          raise newException(ValueError, "inner")
      except ValueError:
        discard
      check isPostgresAllocActive() == false

    check isPostgresAllocActive() == true

    var capturedHandle: XactHandle
    var output = ""
    pgxWithLibcAlloc:
      let capturedTag = "persistent_tag_" & $123
      capturedHandle = onCommit(proc() =
        output = capturedTag
      )

    # Simulate PostgreSQL resetting/destroying the temporary ExprContext
    CurrentMemoryContext = nil
    pgxFireMockXact(cint(ord(xeCommit)))
    check output == "persistent_tag_123"
    check unregisterXactCallback(capturedHandle) == true

  test "Null callback rejection, currentSubTransactionId, and UDF effect compatibility":
    expect(ValueError):
      discard registerXactCallback(nil)
    expect(ValueError):
      discard registerSubXactCallback(nil)
    expect(ValueError):
      discard onCommit(nil)
    expect(ValueError):
      discard onAbort(nil)
    expect(ValueError):
      discard onPreCommit(nil)
    let nilSimple: XactSimpleProc = nil
    let nilSubSimple: SubXactSimpleProc = nil
    expect(ValueError):
      discard onSubXactCommit(nilSimple)
    expect(ValueError):
      discard onSubXactCommit(nilSubSimple)
    expect(ValueError):
      discard onSubXactAbort(nilSimple)
    expect(ValueError):
      discard onSubXactAbort(nilSubSimple)

    mockCurrentSubId = 9'u32
    check currentSubTransactionId() == 9'u32
    let effRes = testEffectSafety()
    check effRes.valid == true
    check effRes.removed == true
