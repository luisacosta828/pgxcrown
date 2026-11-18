import std/strutils

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len >
    0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") & " -I" & (
    if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql") &
    " -include postgres.h".}

import std/unittest

{.emit: """
#include "postgres.h"
#include "storage/lwlock.h"
#include "storage/spin.h"
#include "storage/condition_variable.h"
#include "port/atomics.h"
#include "utils/palloc.h"
#include <stdlib.h>
#include <string.h>

int s_lock(volatile slock_t *lock, const char *file, int line, const char *func) {
    (void)file; (void)line; (void)func;
    while (TAS(lock)) {}
    return 0;
}

/* Stateful C Mocks for LWLock, Tranches, SpinLock, and ConditionVariable */
MemoryContext TopMemoryContext = NULL;
MemoryContext CurrentMemoryContext = NULL;
LWLockPadded mockMainArray[32];
LWLockPadded *MainLWLockArray = mockMainArray;

LWLock *mockHeldLock = NULL;
LWLockMode mockHeldMode = LW_EXCLUSIVE;
int mockAcquireCalls = 0;
int mockReleaseCalls = 0;
int mockDoubleReleaseDetected = 0;

int mockNextTrancheId = 500;
int mockRegisteredTrancheId = -1;
char mockRegisteredTrancheName[128] = {0};
int mockRequestedLocks = 0;
char mockRequestedName[128] = {0};
LWLockPadded mockNamedTranche[8];

int mockCvPrepareCalls = 0;
int mockCvSleepCalls = 0;
int mockCvTimedSleepCalls = 0;
int mockCvCancelCalls = 0;
int mockCvSignalCalls = 0;
int mockCvBroadcastCalls = 0;
int mockCvSleptWithLockHeld = 0;
int mockCvTimedShouldExpire = 0;
int *mockWakeTarget = NULL;
int mockWakeAtSleepCall = 0;

void pgx_reset_lwlock_mocks(void) {
    memset(mockMainArray, 0, sizeof(mockMainArray));
    memset(mockNamedTranche, 0, sizeof(mockNamedTranche));
    mockHeldLock = NULL;
    mockHeldMode = LW_EXCLUSIVE;
    mockAcquireCalls = 0;
    mockReleaseCalls = 0;
    mockDoubleReleaseDetected = 0;
    mockRegisteredTrancheId = -1;
    mockRegisteredTrancheName[0] = '\0';
    mockRequestedLocks = 0;
    mockRequestedName[0] = '\0';
    mockCvPrepareCalls = 0;
    mockCvSleepCalls = 0;
    mockCvTimedSleepCalls = 0;
    mockCvCancelCalls = 0;
    mockCvSignalCalls = 0;
    mockCvBroadcastCalls = 0;
    mockCvSleptWithLockHeld = 0;
    mockCvTimedShouldExpire = 0;
    mockWakeTarget = NULL;
    mockWakeAtSleepCall = 0;
}

bool LWLockAcquire(LWLock *lock, LWLockMode mode) {
    mockAcquireCalls++;
    mockHeldLock = lock;
    mockHeldMode = mode;
    return true;
}

bool LWLockConditionalAcquire(LWLock *lock, LWLockMode mode) {
    if (mockHeldLock == lock) return false;
    mockAcquireCalls++;
    mockHeldLock = lock;
    mockHeldMode = mode;
    return true;
}

bool LWLockAcquireOrWait(LWLock *lock, LWLockMode mode) {
    return LWLockAcquire(lock, mode);
}

void LWLockRelease(LWLock *lock) {
    mockReleaseCalls++;
    if (mockHeldLock != lock) {
        mockDoubleReleaseDetected = 1;
        return;
    }
    mockHeldLock = NULL;
}

void LWLockReleaseAll(void) {
    mockHeldLock = NULL;
}

bool LWLockHeldByMe(LWLock *lock) {
    return lock != NULL && mockHeldLock == lock;
}

bool LWLockHeldByMeInMode(LWLock *lock, LWLockMode mode) {
    return LWLockHeldByMe(lock) && mockHeldMode == mode;
}

void RequestNamedLWLockTranche(const char *tranche_name, int num_lwlocks) {
    mockRequestedLocks = num_lwlocks;
    if (tranche_name) {
        strncpy(mockRequestedName, tranche_name, sizeof(mockRequestedName) - 1);
    }
}

LWLockPadded *GetNamedLWLockTranche(const char *tranche_name) {
    if (tranche_name && strcmp(tranche_name, mockRequestedName) == 0) {
        return mockNamedTranche;
    }
    return NULL;
}

int LWLockNewTrancheId(void) {
    return mockNextTrancheId++;
}

void LWLockRegisterTranche(int tranche_id, const char *tranche_name) {
    mockRegisteredTrancheId = tranche_id;
    mockRegisteredTrancheName[0] = '\0';
    if (tranche_name) {
        strncpy(mockRegisteredTrancheName, tranche_name, sizeof(mockRegisteredTrancheName) - 1);
    }
}

void LWLockInitialize(LWLock *lock, int tranche_id) {
    if (lock) memset(lock, 0, sizeof(LWLock));
    (void)tranche_id;
}

void ConditionVariableInit(ConditionVariable *cv) {
    if (cv) memset(cv, 0, sizeof(ConditionVariable));
}

void ConditionVariablePrepareToSleep(ConditionVariable *cv) {
    (void)cv;
    mockCvPrepareCalls++;
}

void ConditionVariableSleep(ConditionVariable *cv, uint32 wait_event_info) {
    (void)cv; (void)wait_event_info;
    mockCvSleepCalls++;
    if (mockHeldLock != NULL) {
        mockCvSleptWithLockHeld = 1;
    }
    if (mockWakeTarget != NULL && mockCvSleepCalls >= mockWakeAtSleepCall) {
        *mockWakeTarget = 1;
    }
}

bool ConditionVariableTimedSleep(ConditionVariable *cv, long timeout, uint32 wait_event_info) {
    (void)cv; (void)timeout; (void)wait_event_info;
    mockCvTimedSleepCalls++;
    if (mockHeldLock != NULL) {
        mockCvSleptWithLockHeld = 1;
    }
    if (mockWakeTarget != NULL && mockCvTimedSleepCalls >= mockWakeAtSleepCall) {
        *mockWakeTarget = 1;
    }
    return mockCvTimedShouldExpire != 0;
}

#if PG_VERSION_NUM >= 160000
bool ConditionVariableCancelSleep(void) {
    mockCvCancelCalls++;
    return false;
}
#else
void ConditionVariableCancelSleep(void) {
    mockCvCancelCalls++;
}
#endif

void ConditionVariableSignal(ConditionVariable *cv) {
    (void)cv;
    mockCvSignalCalls++;
}

void ConditionVariableBroadcast(ConditionVariable *cv) {
    (void)cv;
    mockCvBroadcastCalls++;
}

char *MemoryContextStrdup(MemoryContext context, const char *string) {
    (void)context;
    if (!string) return NULL;
    size_t n = strlen(string) + 1;
    char *copy = (char *)malloc(n);
    if (copy) memcpy(copy, string, n);
    return copy;
}

size_t pgx_mock_c_sizeof_padded(void) { return sizeof(LWLockPadded); }
size_t pgx_mock_c_sizeof_lwlock(void) { return sizeof(LWLock); }
size_t pgx_mock_c_sizeof_cv(void) { return sizeof(ConditionVariable); }
""".}

import ../src/pgxcrown/lwlock

type
  ValidShmemRecord* {.bycopy.} = object
    lock*: LWLock
    spin*: slock_t
    count32*: pg_atomic_uint32
    count64*: pg_atomic_uint64
    cv*: ConditionVariable
    label*: FixedString[32]

  InvalidStringRecord* {.bycopy.} = object
    lock*: LWLock
    bad*: string

  InvalidSeqRecord* {.bycopy.} = object
    lock*: LWLock
    items*: seq[int32]

  InvalidRefRecord* {.bycopy.} = object
    ptrRef*: ref int

  MockCompositeShmem* {.bycopy.} = object
    lock*: LWLock
    val*: int64

proc resetMocks() {.importc: "pgx_reset_lwlock_mocks", nodecl.}
proc cSizePadded(): csize_t {.importc: "pgx_mock_c_sizeof_padded", nodecl.}
proc cSizeLwlock(): csize_t {.importc: "pgx_mock_c_sizeof_lwlock", nodecl.}
proc cSizeCv(): csize_t {.importc: "pgx_mock_c_sizeof_cv", nodecl.}

proc helperWithEarlyReturn(lock: ptr LWLock): int =
  withLock(lock, lwShared):
    check lock.heldByMe()
    return 99

suite "Pgxcrown - LWLock, Atomics, SpinLock & ConditionVariable Suite":

  test "C-ABI POD enforcement and exact C pgSizeOf (never Nim incomplete fake sizeof)":
    # Reject Nim heap-managed types in shmem allocations at compile time
    check compiles(pgSizeOf[ValidShmemRecord]()) == true
    check compiles(pgSizeOf[InvalidStringRecord]()) == false
    check compiles(pgSizeOf[InvalidSeqRecord]()) == false
    check compiles(pgSizeOf[InvalidRefRecord]()) == false

    # Exact parity with real C compiler sizeof()
    check pgSizeOf[LWLock]() == cSizeLwlock()
    check pgSizeOf[LWLockPadded]() == cSizePadded()
    check pgSizeOf[ConditionVariable]() == cSizeCv()
    check pgSizeOf[MockCompositeShmem]() >= cSizeLwlock() + 8.csize_t

  test "FixedString POD buffer conversions and overflow guards":
    var fs: FixedString[8]
    fs.setStr("pgxc")
    check fs.len == 4'u32
    check $fs == "pgxc"
    check fs.trySetStr("1234567") == true
    check $fs == "1234567"
    check fs.trySetStr("12345678") == false
    expect(ValueError):
      fs.setStr("too_long_string")

  test "Named & Dynamic Tranche helpers and exact LWLockPadded C stride indexing":
    resetMocks()
    requestNamedTranche("pgx_test_tranche", 4)
    let tr = getNamedTranche("pgx_test_tranche")
    check tr != nil
    let p0 = cast[uint](tr[0])
    let p1 = cast[uint](tr[1])
    check (p1 - p0) == uint(cSizePadded())

    var mockRegisteredTrancheId {.importc.}: cint
    var mockRegisteredTrancheName {.importc.}: array[128, char]
    let tid = newTrancheId()
    check tid >= 500
    var localName = "dyn_ipc_" & $tid
    registerTrancheCopy(tid, localName)
    localName = "overwritten_in_caller"
    check mockRegisteredTrancheId == tid
    check $cast[cstring](addr mockRegisteredTrancheName[0]) == ("dyn_ipc_" & $tid)

    let initLck = addinShmemInitLock()
    check initLck != nil

  test "withLock RAII guarantees release on normal exit, early return, and exception":
    resetMocks()
    var mockAcquireCalls {.importc.}: cint
    var mockReleaseCalls {.importc.}: cint
    var mockDoubleReleaseDetected {.importc.}: cint

    var rec: ValidShmemRecord
    let lck = addr rec.lock
    lck.init(501)

    withLock(lck):
      check lck.heldByMe()
    check not lck.heldByMe()
    check mockAcquireCalls == 1
    check mockReleaseCalls == 1
    check mockDoubleReleaseDetected == 0

    check helperWithEarlyReturn(lck) == 99
    check not lck.heldByMe()
    check mockAcquireCalls == 2
    check mockReleaseCalls == 2

    var caught = false
    try:
      withLock(lck, lwExclusive):
        check lck.heldByMe()
        raise newException(ValueError, "boom inside lock")
    except ValueError:
      caught = true
    check caught
    check not lck.heldByMe()
    check mockAcquireCalls == 3
    check mockReleaseCalls == 3

    # Manual release before withLock exit must NOT trigger double-release
    withLock(lck):
      lck.release()
      check not lck.heldByMe()
    check mockDoubleReleaseDetected == 0

    check tryAcquire(lck, lwShared) == true
    check lck.heldByMe()
    check tryAcquire(lck, lwExclusive) == false
    lck.release()

  test "SpinLock acquire, release, and RAII withSpinLock":
    resetMocks()
    var spin: slock_t
    spinLockInit(addr spin)
    check spinLockFree(addr spin)
    withSpinLock(addr spin):
      check not spinLockFree(addr spin)
    check spinLockFree(addr spin)

  test "Atomic flag, uint32, and uint64 operations":
    var flg: pg_atomic_flag
    (addr flg).init()
    check (addr flg).isUnlocked()
    check (addr flg).testAndSet() == true
    check not (addr flg).isUnlocked()
    check (addr flg).testAndSet() == false
    (addr flg).clear()
    check (addr flg).isUnlocked()

    var u32: pg_atomic_uint32
    let p32 = addr u32
    p32.init(10'u32)
    check p32.load() == 10'u32
    check p32.fetchAdd(5) == 10'u32
    check p32.addFetch(2) == 17'u32
    check p32.fetchSub(3) == 17'u32
    check p32.subFetch(4) == 10'u32
    check p32.fetchOr(0x10'u32) == 10'u32
    check p32.fetchAnd(0xFF'u32) == 26'u32
    var exp32 = 99'u32
    check p32.compareExchange(exp32, 42'u32) == false
    check exp32 == 26'u32
    check p32.compareExchange(exp32, 42'u32) == true
    check p32.exchange(7'u32) == 42'u32
    check p32.load() == 7'u32

    var u64: pg_atomic_uint64
    let p64 = addr u64
    p64.init(100'u64)
    check p64.fetchAdd(50) == 100'u64
    check p64.subFetch(25) == 125'u64
    var exp64 = 125'u64
    check p64.compareExchange(exp64, 999'u64) == true
    p64.store(1234'u64)
    check p64.load() == 1234'u64

  test "ConditionVariable waitUntil enforces lockless sleep protocol & timeout handling":
    resetMocks()
    var mockCvPrepareCalls {.importc.}: cint
    var mockCvSleepCalls {.importc.}: cint
    var mockCvTimedSleepCalls {.importc.}: cint
    var mockCvCancelCalls {.importc.}: cint
    var mockCvSleptWithLockHeld {.importc.}: cint
    var mockCvTimedShouldExpire {.importc.}: cint
    var mockWakeTarget {.importc, nodecl.}: ptr cint
    var mockWakeAtSleepCall {.importc, nodecl.}: cint

    var rec: ValidShmemRecord
    (addr rec.lock).init(502)
    (addr rec.cv).init()

    # 1. Spurious wakeup on sleep 1, then condition becomes true on sleep 2
    var readyFlag {.global.}: cint = 0
    readyFlag = 0
    mockWakeTarget = addr readyFlag
    mockWakeAtSleepCall = 2

    let ok = waitUntil(addr rec.cv, addr rec.lock, lwExclusive, -1'i64, PGX_WAIT_EXTENSION):
      readyFlag == 1

    check ok == true
    check mockCvPrepareCalls == 1
    check mockCvSleepCalls == 2
    check mockCvCancelCalls == 1
    check mockCvSleptWithLockHeld == 0
    check not (addr rec.lock).heldByMe()

    # 2. Timed wait expiring returns false cleanly and still cancels sleep
    resetMocks()
    readyFlag = 0
    mockCvTimedShouldExpire = 1
    let timedOut = waitUntil(addr rec.cv, addr rec.lock, lwShared, 50'i64, PGX_WAIT_EXTENSION):
      readyFlag == 1
    check timedOut == false
    check mockCvTimedSleepCalls == 1
    check mockCvCancelCalls == 1
    check mockCvSleptWithLockHeld == 0

    # 3. Zero timeout polls once and never sleeps
    resetMocks()
    readyFlag = 1
    let zeroOk = waitUntil(addr rec.cv, addr rec.lock, lwExclusive, 0'i64, PGX_WAIT_EXTENSION):
      readyFlag == 1
    check zeroOk == true
    check mockCvSleepCalls == 0
    check mockCvTimedSleepCalls == 0
    check mockCvCancelCalls == 1
