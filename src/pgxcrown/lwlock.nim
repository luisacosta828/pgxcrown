## =============================================================================
## Pgxcrown Inter-Process Synchronization Primitives for PostgreSQL (PG 14 - 17)
## =============================================================================
## Provides POD-safe C-ABI bindings and RAII guards for PostgreSQL:
##   - Lightweight Locks (LWLock, Named Tranches, Dynamic Tranches)
##   - SpinLocks (slock_t)
##   - Shared-Memory Atomic Variables (pg_atomic_uint32/64, pg_atomic_flag)
##   - Condition Variables (ConditionVariable + safe waitUntil protocol)
##   - Compile-time C-ABI / POD memory safety guards (assertShmemSafe, pgSizeOf)
## =============================================================================

import std/[typetraits, os]
import ./compiler
import ./memcontext
import ./allocator

const
  PGX_WAIT_EXTENSION* = 0x07000000'u32
  PgxCHeadersDir = currentSourcePath.parentDir / "c_headers"

{.passC: "-I" & quoteShell(PgxCHeadersDir).}

type
  ## Opaque C-ABI PostgreSQL synchronization primitives.
  ## Declared with {.incompleteStruct, bycopy.} so Nim never computes fake sizeof(T)
  ## values; always evaluate allocations via `pgSizeOf[T]()`.
  LWLock* {.importc: "LWLock", header: "storage/lwlock.h", bycopy, incompleteStruct.} = object
  LWLockPadded* {.importc: "LWLockPadded", header: "storage/lwlock.h", bycopy, incompleteStruct.} = object
  LWLockTranche* = ptr LWLockPadded

  LWLockMode* {.size: sizeof(cint).} = enum
    lwExclusive = 0
    lwShared = 1

  slock_t* {.importc: "slock_t", header: "storage/spin.h", bycopy, incompleteStruct.} = object
  SpinLock* = slock_t

  pg_atomic_flag* {.importc: "pg_atomic_flag", header: "port/atomics.h", bycopy, incompleteStruct.} = object
  pg_atomic_uint32* {.importc: "pg_atomic_uint32", header: "port/atomics.h", bycopy, incompleteStruct.} = object
  pg_atomic_uint64* {.importc: "pg_atomic_uint64", header: "port/atomics.h", bycopy, incompleteStruct.} = object

  PgAtomicFlag* = pg_atomic_flag
  PgAtomicU32* = pg_atomic_uint32
  PgAtomicU64* = pg_atomic_uint64

  ConditionVariable* {.importc: "ConditionVariable", header: "storage/condition_variable.h", bycopy, incompleteStruct.} = object

  FixedString*[N: static int] {.bycopy.} = object
    ## POD C-ABI string buffer safe for shared memory (static shmem / DSM).
    len*: uint32
    data*: array[N, char]

# =============================================================================
# Compile-time C-ABI Safety Guards & Exact C sizeof()
# =============================================================================

template assertShmemSafe*(T: typedesc) =
  ## Enforces at compile time that T is a plain C-ABI POD struct ({.bycopy.}
  ## without Nim heap-managed string, seq, Table, ref, closure, or custom destructors).
  when not supportsCopyMem(T):
    {.error: "Shared memory type '" & $T &
      "' must be POD C-ABI ({.bycopy.} without Nim heap references like string/seq/ref). " &
      "Use FixedString[N], array[N, T], or scalar/C-ABI fields instead.".}

proc pgSizeOf*[T](): csize_t {.inline.} =
  ## Evaluates true C sizeof(T) via the C compiler backend (accurate across PG 14-17
  ## and across structs embedding incompleteStruct PG types like LWLock).
  assertShmemSafe(T)
  var sz: csize_t = 0
  {.emit: [sz, " = (size_t)sizeof(", T, ");"].}
  return sz

proc trySetStr*[N: static int](fs: var FixedString[N], val: string): bool {.inline.} =
  ## Copies `val` into FixedString[N] only if it fits in N-1 bytes with null terminator.
  if val.len >= N:
    return false
  fs.len = uint32(val.len)
  if val.len > 0:
    copyMem(addr fs.data[0], unsafeAddr val[0], val.len)
  fs.data[val.len] = '\0'
  return true

proc setStr*[N: static int](fs: var FixedString[N], val: string) {.inline.} =
  ## Copies `val` into FixedString[N], raising ValueError if it exceeds N-1 bytes.
  if not fs.trySetStr(val):
    raise newException(ValueError,
      "FixedString[" & $N & "] overflow: string of " & $val.len &
      " bytes exceeds max " & $(N - 1) & " bytes")

proc getStr*[N: static int](fs: FixedString[N]): string {.inline.} =
  let n = min(int(fs.len), N - 1)
  if n <= 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], unsafeAddr fs.data[0], n)

proc `$`*[N: static int](fs: FixedString[N]): string {.inline.} =
  fs.getStr()

# =============================================================================
# Low-level PostgreSQL C Imports & Shims
# =============================================================================

{.push header: "pgx_ipc.h".}
proc addinShmemInitLock*(): ptr LWLock {.importc: "pgx_addin_shmem_init_lock".}
proc lwlockTrancheAtRaw(arr: LWLockTranche, index: cint): ptr LWLock {.importc: "pgx_lwlock_tranche_at".}
{.pop.}

{.push header: "storage/lwlock.h".}
proc RequestNamedLWLockTranche*(tranche_name: cstring, num_lwlocks: cint) {.importc.}
proc GetNamedLWLockTranche*(tranche_name: cstring): LWLockTranche {.importc.}
proc LWLockNewTrancheId*(): cint {.importc.}
proc LWLockRegisterTranche*(tranche_id: cint, tranche_name: cstring) {.importc.}
proc LWLockInitialize*(lock: ptr LWLock, tranche_id: cint) {.importc.}

proc LWLockAcquire*(lock: ptr LWLock, mode: LWLockMode): bool {.importc.}
proc LWLockConditionalAcquire*(lock: ptr LWLock, mode: LWLockMode): bool {.importc.}
proc LWLockAcquireOrWait*(lock: ptr LWLock, mode: LWLockMode): bool {.importc.}
proc LWLockRelease*(lock: ptr LWLock) {.importc.}
proc LWLockReleaseAll*() {.importc.}
proc LWLockHeldByMe*(lock: ptr LWLock): bool {.importc.}
proc LWLockHeldByMeInMode*(lock: ptr LWLock, mode: LWLockMode): bool {.importc.}
{.pop.}

proc MemoryContextStrdup(context: MemoryContext, s: cstring): cstring {.importc: "MemoryContextStrdup", header: "utils/palloc.h".}

{.push header: "pgx_ipc.h".}
# SpinLock C shims
proc spinLockInit*(lock: ptr slock_t) {.importc: "pgx_spin_init".}
proc spinLockAcquire*(lock: ptr slock_t) {.importc: "pgx_spin_acquire".}
proc spinLockRelease*(lock: ptr slock_t) {.importc: "pgx_spin_release".}
proc spinLockFree*(lock: ptr slock_t): bool {.importc: "pgx_spin_free".}

# Atomics C shims
proc atomicInitFlag*(p: ptr pg_atomic_flag) {.importc: "pgx_atomic_init_flag".}
proc atomicTestSetFlag*(p: ptr pg_atomic_flag): bool {.importc: "pgx_atomic_test_set_flag".}
proc atomicUnlockedTestFlag*(p: ptr pg_atomic_flag): bool {.importc: "pgx_atomic_unlocked_test_flag".}
proc atomicClearFlag*(p: ptr pg_atomic_flag) {.importc: "pgx_atomic_clear_flag".}

proc atomicInitU32*(p: ptr pg_atomic_uint32, val: uint32) {.importc: "pgx_atomic_init_u32".}
proc atomicLoadU32*(p: ptr pg_atomic_uint32): uint32 {.importc: "pgx_atomic_read_u32".}
proc atomicStoreU32*(p: ptr pg_atomic_uint32, val: uint32) {.importc: "pgx_atomic_write_u32".}
proc atomicExchangeU32*(p: ptr pg_atomic_uint32, newval: uint32): uint32 {.importc: "pgx_atomic_exchange_u32".}
proc atomicCompareExchangeU32*(p: ptr pg_atomic_uint32, expected: ptr uint32, newval: uint32): bool {.importc: "pgx_atomic_compare_exchange_u32".}
proc atomicFetchAddU32*(p: ptr pg_atomic_uint32, addval: int32): uint32 {.importc: "pgx_atomic_fetch_add_u32".}
proc atomicFetchSubU32*(p: ptr pg_atomic_uint32, subval: int32): uint32 {.importc: "pgx_atomic_fetch_sub_u32".}
proc atomicAddFetchU32*(p: ptr pg_atomic_uint32, addval: int32): uint32 {.importc: "pgx_atomic_add_fetch_u32".}
proc atomicSubFetchU32*(p: ptr pg_atomic_uint32, subval: int32): uint32 {.importc: "pgx_atomic_sub_fetch_u32".}
proc atomicFetchAndU32*(p: ptr pg_atomic_uint32, andval: uint32): uint32 {.importc: "pgx_atomic_fetch_and_u32".}
proc atomicFetchOrU32*(p: ptr pg_atomic_uint32, orval: uint32): uint32 {.importc: "pgx_atomic_fetch_or_u32".}

proc atomicInitU64*(p: ptr pg_atomic_uint64, val: uint64) {.importc: "pgx_atomic_init_u64".}
proc atomicLoadU64*(p: ptr pg_atomic_uint64): uint64 {.importc: "pgx_atomic_read_u64".}
proc atomicStoreU64*(p: ptr pg_atomic_uint64, val: uint64) {.importc: "pgx_atomic_write_u64".}
proc atomicExchangeU64*(p: ptr pg_atomic_uint64, newval: uint64): uint64 {.importc: "pgx_atomic_exchange_u64".}
proc atomicCompareExchangeU64*(p: ptr pg_atomic_uint64, expected: ptr uint64, newval: uint64): bool {.importc: "pgx_atomic_compare_exchange_u64".}
proc atomicFetchAddU64*(p: ptr pg_atomic_uint64, addval: int64): uint64 {.importc: "pgx_atomic_fetch_add_u64".}
proc atomicFetchSubU64*(p: ptr pg_atomic_uint64, subval: int64): uint64 {.importc: "pgx_atomic_fetch_sub_u64".}
proc atomicAddFetchU64*(p: ptr pg_atomic_uint64, addval: int64): uint64 {.importc: "pgx_atomic_add_fetch_u64".}
proc atomicSubFetchU64*(p: ptr pg_atomic_uint64, subval: int64): uint64 {.importc: "pgx_atomic_sub_fetch_u64".}
proc atomicFetchAndU64*(p: ptr pg_atomic_uint64, andval: uint64): uint64 {.importc: "pgx_atomic_fetch_and_u64".}
proc atomicFetchOrU64*(p: ptr pg_atomic_uint64, orval: uint64): uint64 {.importc: "pgx_atomic_fetch_or_u64".}
{.pop.}

# Condition Variable imports
{.push header: "storage/condition_variable.h".}
proc ConditionVariableInit*(cv: ptr ConditionVariable) {.importc.}
proc ConditionVariablePrepareToSleep*(cv: ptr ConditionVariable) {.importc.}
proc ConditionVariableSleep*(cv: ptr ConditionVariable, wait_event_info: uint32) {.importc.}
proc ConditionVariableTimedSleep*(cv: ptr ConditionVariable, timeout: clong, wait_event_info: uint32): bool {.importc.}
proc ConditionVariableSignal*(cv: ptr ConditionVariable) {.importc.}
proc ConditionVariableBroadcast*(cv: ptr ConditionVariable) {.importc.}
{.pop.}

proc cvCancelSleep*() {.importc: "pgx_cv_cancel_sleep", header: "pgx_ipc.h".}
proc pgxCurrentTimeMs*(): int64 {.importc: "pgx_current_time_ms", header: "pgx_ipc.h".}

# =============================================================================
# Idiomatic Nim Wrappers & RAII Guards
# =============================================================================

proc `[]`*(tranche: LWLockTranche, index: int): ptr LWLock {.inline.} =
  ## Indexes a Named LWLockTranche using real C sizeof(LWLockPadded) stride.
  lwlockTrancheAtRaw(tranche, cint(index))

proc requestNamedTranche*(name: string, numLocks: int) {.inline.} =
  RequestNamedLWLockTranche(cstring(name), cint(numLocks))

proc getNamedTranche*(name: string): LWLockTranche {.inline.} =
  GetNamedLWLockTranche(cstring(name))

proc newTrancheId*(): cint {.inline.} =
  LWLockNewTrancheId()

proc registerTranche*(trancheId: cint, name: cstring) {.inline.} =
  ## Associates a dynamic tranche ID with a static/process-lifetime C string.
  LWLockRegisterTranche(trancheId, name)

proc registerTrancheCopy*(trancheId: cint, name: string) =
  ## Associates a dynamic tranche ID with `name`, cloning the C string into
  ## TopMemoryContext so process-local registration never holds a dangling pointer.
  var persistentName: cstring
  if TopMemoryContext != nil:
    persistentName = MemoryContextStrdup(TopMemoryContext, cstring(name))
  else:
    let buf = cast[cstring](real_malloc(csize_t(name.len + 1)))
    if name.len > 0:
      copyMem(buf, unsafeAddr name[0], name.len)
    cast[ptr UncheckedArray[char]](buf)[name.len] = '\0'
    persistentName = buf
  LWLockRegisterTranche(trancheId, persistentName)

proc init*(lock: ptr LWLock, trancheId: cint) {.inline.} =
  LWLockInitialize(lock, trancheId)

proc acquire*(lock: ptr LWLock, mode: LWLockMode = lwExclusive): bool {.inline, discardable.} =
  LWLockAcquire(lock, mode)

proc tryAcquire*(lock: ptr LWLock, mode: LWLockMode = lwExclusive): bool {.inline.} =
  LWLockConditionalAcquire(lock, mode)

proc release*(lock: ptr LWLock) {.inline.} =
  LWLockRelease(lock)

proc heldByMe*(lock: ptr LWLock): bool {.inline.} =
  LWLockHeldByMe(lock)

template withLock*(lock: ptr LWLock, mode: LWLockMode, body: untyped) =
  ## Acquires `lock` in `mode` and guarantees release in `finally` on normal exit,
  ## early return, or Nim exception (guarded by LWLockHeldByMe to prevent double release).
  let lckPtr = lock
  discard LWLockAcquire(lckPtr, mode)
  try:
    body
  finally:
    if LWLockHeldByMe(lckPtr):
      LWLockRelease(lckPtr)

template withLock*(lock: ptr LWLock, body: untyped) =
  withLock(lock, lwExclusive):
    body

template withSpinLock*(spin: ptr slock_t, body: untyped) =
  ## Acquires `spin` and releases in `finally`.
  ## WARNING: Never call palloc, ereport(ERROR), SPI, or raising/longjmp code inside `body`.
  let spinPtr = spin
  spinLockAcquire(spinPtr)
  try:
    body
  finally:
    spinLockRelease(spinPtr)

# Overloaded ergonomic helpers for pg_atomic_* and ConditionVariable
proc init*(p: ptr pg_atomic_flag) {.inline.} = atomicInitFlag(p)
proc testAndSet*(p: ptr pg_atomic_flag): bool {.inline.} = atomicTestSetFlag(p)
proc isUnlocked*(p: ptr pg_atomic_flag): bool {.inline.} = atomicUnlockedTestFlag(p)
proc clear*(p: ptr pg_atomic_flag) {.inline.} = atomicClearFlag(p)

proc init*(p: ptr pg_atomic_uint32, val: uint32 = 0) {.inline.} = atomicInitU32(p, val)
proc load*(p: ptr pg_atomic_uint32): uint32 {.inline.} = atomicLoadU32(p)
proc store*(p: ptr pg_atomic_uint32, val: uint32) {.inline.} = atomicStoreU32(p, val)
proc exchange*(p: ptr pg_atomic_uint32, val: uint32): uint32 {.inline.} = atomicExchangeU32(p, val)
proc compareExchange*(p: ptr pg_atomic_uint32, expected: var uint32, newVal: uint32): bool {.inline.} =
  atomicCompareExchangeU32(p, addr expected, newVal)
proc fetchAdd*(p: ptr pg_atomic_uint32, delta: int32): uint32 {.inline.} = atomicFetchAddU32(p, delta)
proc fetchSub*(p: ptr pg_atomic_uint32, delta: int32): uint32 {.inline.} = atomicFetchSubU32(p, delta)
proc addFetch*(p: ptr pg_atomic_uint32, delta: int32): uint32 {.inline.} = atomicAddFetchU32(p, delta)
proc subFetch*(p: ptr pg_atomic_uint32, delta: int32): uint32 {.inline.} = atomicSubFetchU32(p, delta)
proc fetchAnd*(p: ptr pg_atomic_uint32, mask: uint32): uint32 {.inline.} = atomicFetchAndU32(p, mask)
proc fetchOr*(p: ptr pg_atomic_uint32, mask: uint32): uint32 {.inline.} = atomicFetchOrU32(p, mask)

proc init*(p: ptr pg_atomic_uint64, val: uint64 = 0) {.inline.} = atomicInitU64(p, val)
proc load*(p: ptr pg_atomic_uint64): uint64 {.inline.} = atomicLoadU64(p)
proc store*(p: ptr pg_atomic_uint64, val: uint64) {.inline.} = atomicStoreU64(p, val)
proc exchange*(p: ptr pg_atomic_uint64, val: uint64): uint64 {.inline.} = atomicExchangeU64(p, val)
proc compareExchange*(p: ptr pg_atomic_uint64, expected: var uint64, newVal: uint64): bool {.inline.} =
  atomicCompareExchangeU64(p, addr expected, newVal)
proc fetchAdd*(p: ptr pg_atomic_uint64, delta: int64): uint64 {.inline.} = atomicFetchAddU64(p, delta)
proc fetchSub*(p: ptr pg_atomic_uint64, delta: int64): uint64 {.inline.} = atomicFetchSubU64(p, delta)
proc addFetch*(p: ptr pg_atomic_uint64, delta: int64): uint64 {.inline.} = atomicAddFetchU64(p, delta)
proc subFetch*(p: ptr pg_atomic_uint64, delta: int64): uint64 {.inline.} = atomicSubFetchU64(p, delta)
proc fetchAnd*(p: ptr pg_atomic_uint64, mask: uint64): uint64 {.inline.} = atomicFetchAndU64(p, mask)
proc fetchOr*(p: ptr pg_atomic_uint64, mask: uint64): uint64 {.inline.} = atomicFetchOrU64(p, mask)

proc init*(cv: ptr ConditionVariable) {.inline.} = ConditionVariableInit(cv)
proc prepareToSleep*(cv: ptr ConditionVariable) {.inline.} = ConditionVariablePrepareToSleep(cv)
proc sleep*(cv: ptr ConditionVariable, waitEventInfo: uint32 = PGX_WAIT_EXTENSION) {.inline.} =
  ConditionVariableSleep(cv, waitEventInfo)
proc timedSleep*(cv: ptr ConditionVariable, timeoutMs: clong, waitEventInfo: uint32 = PGX_WAIT_EXTENSION): bool {.inline.} =
  ConditionVariableTimedSleep(cv, timeoutMs, waitEventInfo)
proc cancelSleep*() {.inline.} = cvCancelSleep()
proc signal*(cv: ptr ConditionVariable) {.inline.} = ConditionVariableSignal(cv)
proc broadcast*(cv: ptr ConditionVariable) {.inline.} = ConditionVariableBroadcast(cv)

template waitUntil*(cv: ptr ConditionVariable, lock: ptr LWLock,
                    mode: LWLockMode, timeoutMs: int64,
                    waitEventInfo: uint32, condExpr: untyped): bool =
  ## Safely waits until `condExpr` evaluates true under `lock` without holding any
  ## LWLock while sleeping on `cv`. Pass `timeoutMs < 0` to wait indefinitely.
  ## Returns true if `condExpr` became true, false on timeout.
  let cvPtr = cv
  let lckPtr = lock
  let reqTimeout = timeoutMs
  let deadlineMs =
    if reqTimeout > 0: pgxCurrentTimeMs() + reqTimeout
    else: -1'i64
  var satisfied = false
  prepareToSleep(cvPtr)
  try:
    while true:
      withLock(lckPtr, mode):
        if condExpr:
          satisfied = true
      if satisfied or reqTimeout == 0:
        break
      if reqTimeout > 0:
        let nowMs = pgxCurrentTimeMs()
        let remMs = deadlineMs - nowMs
        if remMs <= 0:
          break
        if timedSleep(cvPtr, clong(remMs), waitEventInfo):
          withLock(lckPtr, mode):
            if condExpr:
              satisfied = true
          break
      else:
        sleep(cvPtr, waitEventInfo)
  finally:
    cancelSleep()
  satisfied

template waitUntil*(cv: ptr ConditionVariable, lock: ptr LWLock,
                    condExpr: untyped): bool =
  waitUntil(cv, lock, lwExclusive, -1'i64, PGX_WAIT_EXTENSION, condExpr)
