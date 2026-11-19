## =============================================================================
## Pgxcrown Shared Memory & Dynamic Shared Memory (PG 14 - 17)
## =============================================================================
## Unified POD-safe bindings and helpers for:
##   1. Static Shared Memory (shared_preload_libraries + chained request/startup hooks + ShmemInitStruct)
##   2. Dynamic Shared Memory (dsm_segment lifecycle, ResourceOwner pinning, shm_toc allocator)
##   3. Optional PG 17 Named DSM Registry (GetNamedDSMSegment)
## =============================================================================

import std/os
import ./compiler
import ./lwlock
import ./memcontext
import ./datatypes/basic
import ./reports/reports

const
  PgxShmemCHeadersDir = currentSourcePath.parentDir / "c_headers"
  SHMEM_INDEX_KEYSIZE* = 48
  DSM_HANDLE_INVALID* = 0'u32
  DSM_CREATE_NULL_IF_MAXSEGMENTS* = 0x0001'i32

{.passC: "-I" & quoteShell(PgxShmemCHeadersDir).}

type
  DsmSegmentObj* {.importc: "dsm_segment", header: "storage/dsm.h", incompleteStruct.} = object
  DsmSegment* = ptr DsmSegmentObj
  DsmHandle* = uint32

  DsmDetachCallback* = proc(seg: DsmSegment, arg: Datum) {.cdecl.}

  ShmTocObj* {.importc: "shm_toc", header: "storage/shm_toc.h", incompleteStruct.} = object
  ShmTocPtr* = ptr ShmTocObj

  ShmTocEstimator* {.importc: "shm_toc_estimator", header: "storage/shm_toc.h", bycopy.} = object
    space_for_chunks*: csize_t
    number_of_keys*: csize_t

  PgxShmemCHook* = proc() {.cdecl.}
  PgxNamedDsmInitCb* = proc(p: pointer) {.cdecl.}
  PgxShmemCallback* = proc()

# Low-level PostgreSQL C imports
{.push header: "storage/shmem.h".}
proc RequestAddinShmemSpace*(size: csize_t) {.importc.}
proc ShmemInitStruct*(name: cstring, size: csize_t, foundPtr: ptr bool): pointer {.importc.}
proc cAddSize(s1, s2: csize_t): csize_t {.importc: "add_size".}
proc cMulSize(s1, s2: csize_t): csize_t {.importc: "mul_size".}
{.pop.}

{.push header: "storage/dsm.h".}
proc cDsmCreate(size: csize_t, flags: cint): DsmSegment {.importc: "dsm_create".}
proc cDsmAttach(h: DsmHandle): DsmSegment {.importc: "dsm_attach".}
proc cDsmDetach(seg: DsmSegment) {.importc: "dsm_detach".}
proc cDsmPinMapping(seg: DsmSegment) {.importc: "dsm_pin_mapping".}
proc cDsmUnpinMapping(seg: DsmSegment) {.importc: "dsm_unpin_mapping".}
proc cDsmPinSegment(seg: DsmSegment) {.importc: "dsm_pin_segment".}
proc cDsmUnpinSegment(h: DsmHandle) {.importc: "dsm_unpin_segment".}
proc cDsmFindMapping(h: DsmHandle): DsmSegment {.importc: "dsm_find_mapping".}
proc cDsmSegmentAddress(seg: DsmSegment): pointer {.importc: "dsm_segment_address".}
proc cDsmSegmentMapLength(seg: DsmSegment): csize_t {.importc: "dsm_segment_map_length".}
proc cDsmSegmentHandle(seg: DsmSegment): DsmHandle {.importc: "dsm_segment_handle".}
proc cOnDsmDetach(seg: DsmSegment, fn: DsmDetachCallback, arg: Datum) {.importc: "on_dsm_detach".}
proc cCancelOnDsmDetach(seg: DsmSegment, fn: DsmDetachCallback, arg: Datum) {.importc: "cancel_on_dsm_detach".}
{.pop.}

{.push header: "storage/shm_toc.h".}
proc cShmTocCreate(magic: uint64, address: pointer, nbytes: csize_t): ShmTocPtr {.importc: "shm_toc_create".}
proc cShmTocAttach(magic: uint64, address: pointer): ShmTocPtr {.importc: "shm_toc_attach".}
proc cShmTocAllocate(toc: ShmTocPtr, nbytes: csize_t): pointer {.importc: "shm_toc_allocate".}
proc cShmTocFreespace(toc: ShmTocPtr): csize_t {.importc: "shm_toc_freespace".}
proc cShmTocInsert(toc: ShmTocPtr, key: uint64, address: pointer) {.importc: "shm_toc_insert".}
proc cShmTocLookup(toc: ShmTocPtr, key: uint64, noError: bool): pointer {.importc: "shm_toc_lookup".}
proc cShmTocEstimate(e: ptr ShmTocEstimator): csize_t {.importc: "shm_toc_estimate".}
{.pop.}

{.push header: "pgx_ipc.h".}
proc pgxMaxAlign(sz: csize_t): csize_t {.importc: "pgx_maxalign".}
proc pgxBufferAlign(sz: csize_t): csize_t {.importc: "pgx_bufferalign".}
proc pgxShmTocInitEstimator(e: ptr ShmTocEstimator) {.importc: "pgx_shm_toc_init_estimator".}
proc pgxShmTocEstimateChunk(e: ptr ShmTocEstimator, sz: csize_t) {.importc: "pgx_shm_toc_estimate_chunk".}
proc pgxShmTocEstimateKeys(e: ptr ShmTocEstimator, cnt: csize_t) {.importc: "pgx_shm_toc_estimate_keys".}
proc pgxHasShmemRequestHook(): bool {.importc: "pgx_has_shmem_request_hook".}
proc isSharedPreloadInProgress*(): bool {.importc: "pgx_is_shared_preload_in_progress".}
proc pgxGetShmemStartupHook(): PgxShmemCHook {.importc: "pgx_get_shmem_startup_hook".}
proc pgxSetShmemStartupHook(fn: PgxShmemCHook) {.importc: "pgx_set_shmem_startup_hook".}
proc pgxGetShmemRequestHook(): PgxShmemCHook {.importc: "pgx_get_shmem_request_hook".}
proc pgxSetShmemRequestHook(fn: PgxShmemCHook) {.importc: "pgx_set_shmem_request_hook".}
proc pgxHasNamedDsmRegistry*(): bool {.importc: "pgx_has_named_dsm_registry".}
proc pgxGetNamedDsmSegment(name: cstring, size: csize_t, initCb: PgxNamedDsmInitCb, found: ptr bool): pointer {.importc: "pgx_get_named_dsm_segment".}
{.pop.}

# =============================================================================
# Size & Alignment Helpers
# =============================================================================

proc maxAlign*(sz: csize_t): csize_t {.inline.} = pgxMaxAlign(sz)
proc bufferAlign*(sz: csize_t): csize_t {.inline.} = pgxBufferAlign(sz)
proc addSize*(a, b: csize_t): csize_t {.inline.} = cAddSize(a, b)
proc mulSize*(a, b: csize_t): csize_t {.inline.} = cMulSize(a, b)

# =============================================================================
# Static Shared Memory API (shared_preload_libraries, Unified PG 14 - 17)
# =============================================================================

var
  activeNimRequestHook {.global.}: PgxShmemCallback = nil
  activeNimStartupHook {.global.}: PgxShmemCallback = nil
  prevShmemRequestHook {.global.}: PgxShmemCHook = nil
  userShmemRequestHook {.global.}: PgxShmemCHook = nil
  prevShmemStartupHook {.global.}: PgxShmemCHook = nil
  userShmemStartupHook {.global.}: PgxShmemCHook = nil

proc trampolineShmemRequest() {.cdecl.} =
  if prevShmemRequestHook != nil:
    prevShmemRequestHook()
  if userShmemRequestHook != nil:
    userShmemRequestHook()

proc trampolineShmemStartup() {.cdecl.} =
  if prevShmemStartupHook != nil:
    prevShmemStartupHook()
  if userShmemStartupHook != nil:
    userShmemStartupHook()

proc runGuardedHookCallback(cb: PgxShmemCallback, phaseName: string) =
  if cb == nil:
    return
  var errPending = false
  var errCode: cint = 0
  var errMsg: cstring = nil
  var errDetail: cstring = nil
  var errHint: cstring = nil
  try:
    withTopMemoryContext:
      cb()
  except Defect as e:
    prepareNimDefect(e, errCode, errMsg, errDetail, errHint)
    errPending = true
  except CatchableError as e:
    prepareNimError(e, errCode, errMsg, errDetail, errHint)
    errPending = true
  if errPending:
    pgxEreportFull(ERROR, errCode, errMsg, errDetail, errHint)

proc dispatchRequestHook {.cdecl.} =
  runGuardedHookCallback(activeNimRequestHook, "shmem_request")

proc dispatchStartupHook {.cdecl.} =
  runGuardedHookCallback(activeNimStartupHook, "shmem_startup")

proc installShmemHooksRaw*(onRequest: PgxShmemCHook, onStartup: PgxShmemCHook) =
  ## Installs low-level cdecl shmem hooks (PG 15-17 chained shmem_request_hook + shmem_startup_hook;
  ## PG 14 executes onRequest immediately inside _PG_init and chains shmem_startup_hook).
  if onRequest != nil and not isSharedPreloadInProgress():
    raise newException(ValueError,
      "Shared memory hooks require the extension to be loaded via 'shared_preload_libraries'.")

  if onRequest != nil:
    userShmemRequestHook = onRequest
    if pgxHasShmemRequestHook():
      let curReq = pgxGetShmemRequestHook()
      if curReq != trampolineShmemRequest:
        prevShmemRequestHook = curReq
        pgxSetShmemRequestHook(trampolineShmemRequest)
    else:
      # PG 14 has no shmem_request_hook; request shared memory immediately during _PG_init
      onRequest()

  if onStartup != nil:
    userShmemStartupHook = onStartup
    let curStart = pgxGetShmemStartupHook()
    if curStart != trampolineShmemStartup:
      prevShmemStartupHook = curStart
      pgxSetShmemStartupHook(trampolineShmemStartup)

proc installShmemHooks*(onRequest: PgxShmemCallback, onStartup: PgxShmemCallback) =
  ## Installs Nim shared memory request/startup hooks uniformly across PG 14-17.
  ## Wraps callbacks in TopMemoryContext and translates Nim exceptions into PostgreSQL errors.
  activeNimRequestHook = onRequest
  activeNimStartupHook = onStartup
  let reqFn: PgxShmemCHook = if onRequest != nil: dispatchRequestHook else: nil
  let startFn: PgxShmemCHook = if onStartup != nil: dispatchStartupHook else: nil
  installShmemHooksRaw(reqFn, startFn)

proc requestShmemSpace*(bytes: csize_t) {.inline.} =
  RequestAddinShmemSpace(bytes)

proc requestShmemSpace*[T](extraBytes: csize_t = 0) {.inline.} =
  ## Requests aligned shared memory space sufficient for POD type T plus optional extraBytes.
  assertShmemSafe(T)
  let total = addSize(maxAlign(pgSizeOf[T]()), maxAlign(extraBytes))
  RequestAddinShmemSpace(total)

proc initShmemStruct*[T](name: string, initCb: proc(p: ptr T) = nil): tuple[data: ptr T, found: bool] =
  ## Atomically acquires AddinShmemInitLock, allocates or looks up a named POD shared struct `T`,
  ## zeroes newly allocated memory, and executes `initCb` only on first creation (`found == false`).
  assertShmemSafe(T)
  if name.len == 0 or name.len >= SHMEM_INDEX_KEYSIZE:
    raise newException(ValueError,
      "ShmemInitStruct name length (" & $name.len & ") must be between 1 and " &
      $(SHMEM_INDEX_KEYSIZE - 1) & " bytes (SHMEM_INDEX_KEYSIZE=" & $SHMEM_INDEX_KEYSIZE & ")")
  var alreadyFound = false
  var rawPtr: pointer = nil
  let sz = pgSizeOf[T]()
  withLock(addinShmemInitLock(), lwExclusive):
    rawPtr = ShmemInitStruct(cstring(name), sz, addr alreadyFound)
    if rawPtr == nil:
      raise newException(Defect, "ShmemInitStruct returned NULL for '" & name & "'")
    if not alreadyFound:
      zeroMem(rawPtr, sz)
      if initCb != nil:
        initCb(cast[ptr T](rawPtr))
  return (cast[ptr T](rawPtr), alreadyFound)

# =============================================================================
# Dynamic Shared Memory (DSM) & shm_toc API (No preload required)
# =============================================================================

proc cPgxEnsureResourceOwner(name: cstring) {.importc: "pgx_ensure_resource_owner", header: "pgx_ipc.h".}

proc ensureResourceOwner*(name: cstring = "pgx_worker") {.inline.} =
  ## Ensures `CurrentResourceOwner` is initialized (required before `dsmAttach`
  ## or `dsmCreate` in shmem-only background workers that have no active transaction).
  cPgxEnsureResourceOwner(name)

proc dsmCreate*(size: csize_t, flags: cint = 0): DsmSegment {.inline.} =
  cDsmCreate(size, flags)

proc dsmAttach*(handle: DsmHandle): DsmSegment {.inline.} =
  if handle == DSM_HANDLE_INVALID:
    raise newException(ValueError, "Cannot attach to invalid DSM handle (0)")
  cDsmAttach(handle)

proc dsmFindMapping*(handle: DsmHandle): DsmSegment {.inline.} =
  if handle == DSM_HANDLE_INVALID:
    return nil
  cDsmFindMapping(handle)

proc dsmAttachOrFind*(handle: DsmHandle): DsmSegment {.inline.} =
  ## Returns an existing process mapping for `handle` if already attached,
  ## or attaches a new mapping safely. Prevents duplicate-attach errors.
  if handle == DSM_HANDLE_INVALID:
    raise newException(ValueError, "Cannot attach to invalid DSM handle (0)")
  let existing = cDsmFindMapping(handle)
  if existing != nil:
    return existing
  return cDsmAttach(handle)

proc dsmDetach*(seg: DsmSegment) {.inline.} =
  if seg != nil:
    cDsmDetach(seg)

proc dsmPinMapping*(seg: DsmSegment) {.inline.} =
  ## Keeps the mapping attached beyond CurrentResourceOwner (until process exit or dsmUnpinMapping).
  if seg != nil:
    cDsmPinMapping(seg)

proc dsmUnpinMapping*(seg: DsmSegment) {.inline.} =
  if seg != nil:
    cDsmUnpinMapping(seg)

proc dsmPinSegment*(seg: DsmSegment) {.inline.} =
  ## Keeps the DSM segment alive across all backends even with zero active mappings until unpinned or shutdown.
  if seg != nil:
    cDsmPinSegment(seg)

proc dsmUnpinSegment*(handle: DsmHandle) {.inline.} =
  if handle != DSM_HANDLE_INVALID:
    cDsmUnpinSegment(handle)

proc dsmAddress*(seg: DsmSegment): pointer {.inline.} =
  cDsmSegmentAddress(seg)

proc dsmMapLength*(seg: DsmSegment): csize_t {.inline.} =
  cDsmSegmentMapLength(seg)

proc dsmHandle*(seg: DsmSegment): DsmHandle {.inline.} =
  cDsmSegmentHandle(seg)

proc onDsmDetach*(seg: DsmSegment, fn: DsmDetachCallback, arg: Datum = Datum(0)) {.inline.} =
  cOnDsmDetach(seg, fn, arg)

proc cancelOnDsmDetach*(seg: DsmSegment, fn: DsmDetachCallback, arg: Datum = Datum(0)) {.inline.} =
  cCancelOnDsmDetach(seg, fn, arg)

# shm_toc Estimator & Regions
proc initEstimator*(): ShmTocEstimator {.inline.} =
  pgxShmTocInitEstimator(addr result)

proc estimateChunk*(est: var ShmTocEstimator, size: csize_t) {.inline.} =
  pgxShmTocEstimateChunk(addr est, size)

proc estimateChunk*[T](est: var ShmTocEstimator) {.inline.} =
  assertShmemSafe(T)
  pgxShmTocEstimateChunk(addr est, pgSizeOf[T]())

proc estimateKeys*(est: var ShmTocEstimator, count: csize_t = 1) {.inline.} =
  pgxShmTocEstimateKeys(addr est, count)

proc estimate*(est: var ShmTocEstimator): csize_t {.inline.} =
  cShmTocEstimate(addr est)

proc createToc*(seg: DsmSegment, magic: uint64): ShmTocPtr {.inline.} =
  if seg == nil:
    raise newException(ValueError, "Cannot create shm_toc on nil DsmSegment")
  cShmTocCreate(magic, dsmAddress(seg), dsmMapLength(seg))

proc attachToc*(seg: DsmSegment, magic: uint64): ShmTocPtr {.inline.} =
  if seg == nil:
    raise newException(ValueError, "Cannot attach shm_toc on nil DsmSegment")
  cShmTocAttach(magic, dsmAddress(seg))

proc tocFreespace*(toc: ShmTocPtr): csize_t {.inline.} =
  cShmTocFreespace(toc)

proc allocBytes*(toc: ShmTocPtr, key: uint64, size: csize_t): pointer {.inline.} =
  let raw = cShmTocAllocate(toc, size)
  if raw == nil:
    raise newException(Defect, "shm_toc_allocate failed (insufficient freespace)")
  if size > 0:
    zeroMem(raw, size)
  cShmTocInsert(toc, key, raw)
  return raw

proc allocStruct*[T](toc: ShmTocPtr, key: uint64): ptr T {.inline.} =
  assertShmemSafe(T)
  let raw = allocBytes(toc, key, pgSizeOf[T]())
  return cast[ptr T](raw)

proc lookupBytes*(toc: ShmTocPtr, key: uint64, noError: bool = false): pointer {.inline.} =
  cShmTocLookup(toc, key, noError)

proc lookupStruct*[T](toc: ShmTocPtr, key: uint64, noError: bool = false): ptr T {.inline.} =
  assertShmemSafe(T)
  cast[ptr T](cShmTocLookup(toc, key, noError))

proc getNamedDsmSegment*(name: string, size: csize_t, initCb: PgxNamedDsmInitCb, found: var bool): pointer =
  ## PG 17+ Named DSM Registry helper (raises ValueError cleanly on PG < 17).
  if not pgxHasNamedDsmRegistry():
    raise newException(ValueError, "GetNamedDSMSegment requires PostgreSQL 17 or newer")
  return pgxGetNamedDsmSegment(cstring(name), size, initCb, addr found)
