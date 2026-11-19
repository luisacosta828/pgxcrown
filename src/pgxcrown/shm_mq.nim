## =============================================================================
## Pgxcrown Shared Memory Message Queues (shm_mq) for PostgreSQL (PG 14 - 17)
## =============================================================================
## Single-Producer, Single-Consumer (SPSC) lock-free ring-buffer message queues
## built on PostgreSQL's `storage/shm_mq.h`.
##
## Features:
##   - Transparent PG 14 (4-arg) vs PG 15-17 (5-arg `force_flush`) send shims
##   - Minimum queue size validation (`shmMqMinimumSize()`)
##   - Zero-copy receive (`receiveZeroCopy`) and owned string/byte helpers
##   - Bidirectional RPC channel layout helper over `shm_toc`
## =============================================================================

import std/os
import ./compiler
import ./lwlock
import ./shmem
import ./bgworker

const
  PgxMqCHeadersDir = currentSourcePath.parentDir / "c_headers"

{.passC: "-I" & quoteShell(PgxMqCHeadersDir).}

type
  PgProc* {.importc: "PGPROC", header: "storage/proc.h", incompleteStruct.} = object
  PgProcPtr* = ptr PgProc

  ShmMq* {.importc: "shm_mq", header: "storage/shm_mq.h", incompleteStruct.} = object
  ShmMqPtr* = ptr ShmMq

  ShmMqHandle* {.importc: "shm_mq_handle", header: "storage/shm_mq.h", incompleteStruct.} = object
  ShmMqHandlePtr* = ptr ShmMqHandle

  ShmMqIovec* {.importc: "shm_mq_iovec", header: "storage/shm_mq.h", bycopy.} = object
    data*: cstring
    len*: csize_t

  ShmMqResult* {.importc: "shm_mq_result", header: "storage/shm_mq.h", size: sizeof(cint).} = enum
    mqSuccess = 0
    mqWouldBlock = 1
    mqDetached = 2

  ShmRpcChannel* = object
    reqMq*: ShmMqPtr
    respMq*: ShmMqPtr

  ShmChannel*[T] = object
    ## Type-safe POD wrapper around an attached `shm_mq_handle`.
    mq*: ShmMqPtr
    handle*: ShmMqHandlePtr

# -----------------------------------------------------------------------------
# Raw C Imports
# -----------------------------------------------------------------------------

proc cMyProc(): PgProcPtr {.importc: "pgx_my_proc", header: "pgx_ipc.h".}
proc cShmMqMinSize(): csize_t {.importc: "pgx_shm_mq_min_size", header: "pgx_ipc.h".}

proc cShmMqCreate(address: pointer, size: csize_t): ShmMqPtr {.importc: "shm_mq_create", header: "storage/shm_mq.h".}
proc cShmMqSetSender(mq: ShmMqPtr, procPtr: PgProcPtr) {.importc: "shm_mq_set_sender", header: "storage/shm_mq.h".}
proc cShmMqSetReceiver(mq: ShmMqPtr, procPtr: PgProcPtr) {.importc: "shm_mq_set_receiver", header: "storage/shm_mq.h".}
proc cShmMqAttach(mq: ShmMqPtr, seg: DsmSegment,
    bgwHandle: BackgroundWorkerHandlePtr): ShmMqHandlePtr {.importc: "shm_mq_attach", header: "storage/shm_mq.h".}
proc cShmMqSetHandle(mqh: ShmMqHandlePtr,
    bgwHandle: BackgroundWorkerHandlePtr) {.importc: "shm_mq_set_handle", header: "storage/shm_mq.h".}
proc cShmMqDetach(mqh: ShmMqHandlePtr) {.importc: "shm_mq_detach", header: "storage/shm_mq.h".}
proc cShmMqWaitForAttach(mqh: ShmMqHandlePtr): ShmMqResult {.importc: "shm_mq_wait_for_attach", header: "storage/shm_mq.h".}
proc cShmMqSend(mqh: ShmMqHandlePtr, nbytes: csize_t, data: pointer,
    nowait: bool, forceFlush: bool): ShmMqResult {.importc: "pgx_shm_mq_send", header: "pgx_ipc.h".}
proc cShmMqSendv(mqh: ShmMqHandlePtr, iov: ptr ShmMqIovec, iovcnt: cint,
    nowait: bool, forceFlush: bool): ShmMqResult {.importc: "pgx_shm_mq_sendv", header: "pgx_ipc.h".}
proc cShmMqReceive(mqh: ShmMqHandlePtr, nbytesp: ptr csize_t, datap: ptr pointer,
    nowait: bool): ShmMqResult {.importc: "shm_mq_receive", header: "storage/shm_mq.h".}

# -----------------------------------------------------------------------------
# Public Idiomatic API
# -----------------------------------------------------------------------------

proc myProc*(): PgProcPtr {.inline.} =
  ## Returns the current PostgreSQL backend/worker `PGPROC*` (`MyProc`).
  cMyProc()

proc shmMqMinimumSize*(): csize_t {.inline.} =
  ## Returns PostgreSQL's minimum required byte size for a `shm_mq` ring buffer.
  cShmMqMinSize()

proc createMq*(address: pointer, size: csize_t): ShmMqPtr =
  ## Initializes a new `shm_mq` ring buffer at `address` with `size` bytes.
  ## Raises `ValueError` if `address` is nil or `size < shmMqMinimumSize()`.
  if address == nil:
    raise newException(ValueError, "createMq: address cannot be nil")
  let minSz = shmMqMinimumSize()
  if size < minSz:
    raise newException(ValueError,
      "createMq: queue size (" & $size & " bytes) is smaller than shm_mq_minimum_size (" &
      $minSz & " bytes)")
  cShmMqCreate(address, size)

proc setSender*(mq: ShmMqPtr, procPtr: PgProcPtr = myProc()) {.inline.} =
  ## Binds the single sender `PGPROC` for this SPSC message queue.
  cShmMqSetSender(mq, procPtr)

proc setReceiver*(mq: ShmMqPtr, procPtr: PgProcPtr = myProc()) {.inline.} =
  ## Binds the single receiver `PGPROC` for this SPSC message queue.
  cShmMqSetReceiver(mq, procPtr)

proc attachMq*(mq: ShmMqPtr, seg: DsmSegment = nil,
    bgwHandle: BackgroundWorkerHandlePtr = nil): ShmMqHandlePtr {.inline.} =
  ## Attaches the current process to a `shm_mq` (either as sender or receiver).
  cShmMqAttach(mq, seg, bgwHandle)

proc attachMq*(mq: ShmMqPtr, seg: DsmSegment,
    worker: WorkerHandle): ShmMqHandlePtr {.inline.} =
  ## Attaches the current process to a `shm_mq` associated with a `WorkerHandle`,
  ## enabling automatic `mqDetached` detection if the background worker dies.
  cShmMqAttach(mq, seg, worker.raw)

proc setWorkerHandle*(mqh: ShmMqHandlePtr, worker: WorkerHandle) {.inline.} =
  ## Associates a `WorkerHandle` with an already-attached `shm_mq_handle` so
  ## blocking sends/receives wake up with `mqDetached` if the worker terminates.
  cShmMqSetHandle(mqh, worker.raw)

proc detachMq*(mqh: ShmMqHandlePtr) {.inline.} =
  ## Detaches from a `shm_mq_handle`, notifying the peer with `mqDetached`.
  if mqh != nil:
    cShmMqDetach(mqh)

proc waitForAttach*(mqh: ShmMqHandlePtr): ShmMqResult {.inline.} =
  ## Waits until the peer process attaches to the other end of the queue.
  cShmMqWaitForAttach(mqh)

proc send*(mqh: ShmMqHandlePtr, data: pointer, nbytes: csize_t,
    nowait: bool = false, forceFlush: bool = true): ShmMqResult {.inline.} =
  ## Sends raw bytes through the `shm_mq` handle.
  ## `forceFlush` defaults to `true` for low-latency RPC wakeup (PG 15-17; ignored on PG 14).
  cShmMqSend(mqh, nbytes, data, nowait, forceFlush)

proc send*(mqh: ShmMqHandlePtr, payload: string,
    nowait: bool = false, forceFlush: bool = true): ShmMqResult =
  ## Sends a Nim `string` payload through the `shm_mq` handle.
  if payload.len == 0:
    var emptyByte: uint8 = 0
    return cShmMqSend(mqh, 0.csize_t, addr emptyByte, nowait, forceFlush)
  cShmMqSend(mqh, csize_t(payload.len), unsafeAddr payload[0], nowait, forceFlush)

proc send*(mqh: ShmMqHandlePtr, payload: openArray[byte],
    nowait: bool = false, forceFlush: bool = true): ShmMqResult =
  ## Sends a byte slice through the `shm_mq` handle.
  if payload.len == 0:
    var emptyByte: uint8 = 0
    return cShmMqSend(mqh, 0.csize_t, addr emptyByte, nowait, forceFlush)
  cShmMqSend(mqh, csize_t(payload.len), unsafeAddr payload[0], nowait, forceFlush)

proc sendv*(mqh: ShmMqHandlePtr, iovs: openArray[ShmMqIovec],
    nowait: bool = false, forceFlush: bool = true): ShmMqResult =
  ## Scatter-gather send of multiple `ShmMqIovec` buffers as a single message.
  if iovs.len == 0:
    var emptyByte: uint8 = 0
    return cShmMqSend(mqh, 0.csize_t, addr emptyByte, nowait, forceFlush)
  cShmMqSendv(mqh, cast[ptr ShmMqIovec](unsafeAddr iovs[0]), cint(iovs.len), nowait, forceFlush)

proc receiveZeroCopy*(mqh: ShmMqHandlePtr,
    nowait: bool = false): tuple[status: ShmMqResult, data: pointer, nbytes: csize_t] =
  ## Zero-copy receive from `shm_mq`. The returned `data` pointer remains valid
  ## only until the next `receive*` or `detachMq` call on `mqh`.
  var nbytes: csize_t = 0
  var dataPtr: pointer = nil
  let st = cShmMqReceive(mqh, addr nbytes, addr dataPtr, nowait)
  (status: st, data: dataPtr, nbytes: nbytes)

proc receive*(mqh: ShmMqHandlePtr,
    nowait: bool = false): tuple[status: ShmMqResult, payload: string] =
  ## Receives a message and copies it into an owned Nim `string`.
  let r = receiveZeroCopy(mqh, nowait)
  if r.status != mqSuccess:
    return (status: r.status, payload: "")
  if r.nbytes == 0 or r.data == nil:
    return (status: mqSuccess, payload: "")
  var s = newString(int(r.nbytes))
  copyMem(addr s[0], r.data, int(r.nbytes))
  (status: mqSuccess, payload: s)

proc receiveBytes*(mqh: ShmMqHandlePtr,
    nowait: bool = false): tuple[status: ShmMqResult, payload: seq[byte]] =
  ## Receives a message and copies it into an owned `seq[byte]`.
  let r = receiveZeroCopy(mqh, nowait)
  if r.status != mqSuccess:
    return (status: r.status, payload: @[])
  if r.nbytes == 0 or r.data == nil:
    return (status: mqSuccess, payload: @[])
  var buf = newSeq[byte](int(r.nbytes))
  copyMem(addr buf[0], r.data, int(r.nbytes))
  (status: mqSuccess, payload: buf)

# -----------------------------------------------------------------------------
# Bidirectional RPC Channel Helper over shm_toc
# -----------------------------------------------------------------------------

proc estimateRpcQueues*(e: var ShmTocEstimator,
    reqQueueSize: csize_t, respQueueSize: csize_t) =
  ## Adds estimation for a bidirectional request/response `shm_mq` pair to a `ShmTocEstimator`.
  e.estimateChunk(reqQueueSize)
  e.estimateChunk(respQueueSize)
  e.estimateKeys(2)

proc createRpcQueues*(toc: ShmTocPtr, reqKey, respKey: uint64,
    reqQueueSize, respQueueSize: csize_t): ShmRpcChannel =
  ## Allocates and initializes two `shm_mq` queues (`reqMq` and `respMq`) inside `toc`.
  let reqMem = toc.allocBytes(reqKey, reqQueueSize)
  let respMem = toc.allocBytes(respKey, respQueueSize)
  result.reqMq = createMq(reqMem, reqQueueSize)
  result.respMq = createMq(respMem, respQueueSize)

proc lookupRpcQueues*(toc: ShmTocPtr, reqKey, respKey: uint64): ShmRpcChannel =
  ## Looks up an existing bidirectional `shm_mq` pair inside `toc`.
  result.reqMq = cast[ShmMqPtr](toc.lookupBytes(reqKey))
  result.respMq = cast[ShmMqPtr](toc.lookupBytes(respKey))

# -----------------------------------------------------------------------------
# Typed Generic Channel API: ShmChannel[T] (Compile-Time POD Enforced)
# -----------------------------------------------------------------------------

proc asChannel*[T](handle: ShmMqHandlePtr, mq: ShmMqPtr = nil): ShmChannel[T] {.inline.} =
  ## Wraps an existing attached `shm_mq_handle` into a typed `ShmChannel[T]`.
  assertShmemSafe(T)
  ShmChannel[T](mq: mq, handle: handle)

proc openSendChannel*[T](mq: ShmMqPtr, seg: DsmSegment = nil,
    worker: WorkerHandle = WorkerHandle(raw: nil)): ShmChannel[T] =
  ## Binds the current process as sender on `mq` and attaches a typed `ShmChannel[T]`.
  assertShmemSafe(T)
  if mq == nil:
    raise newException(ValueError, "openSendChannel: mq cannot be nil")
  mq.setSender(myProc())
  let h = attachMq(mq, seg, worker.raw)
  ShmChannel[T](mq: mq, handle: h)

proc openRecvChannel*[T](mq: ShmMqPtr, seg: DsmSegment = nil,
    worker: WorkerHandle = WorkerHandle(raw: nil)): ShmChannel[T] =
  ## Binds the current process as receiver on `mq` and attaches a typed `ShmChannel[T]`.
  assertShmemSafe(T)
  if mq == nil:
    raise newException(ValueError, "openRecvChannel: mq cannot be nil")
  mq.setReceiver(myProc())
  let h = attachMq(mq, seg, worker.raw)
  ShmChannel[T](mq: mq, handle: h)

proc close*[T](ch: var ShmChannel[T]) {.inline.} =
  ## Detaches the underlying `shm_mq_handle` if currently open.
  if ch.handle != nil:
    detachMq(ch.handle)
    ch.handle = nil

proc setWorkerHandle*[T](ch: ShmChannel[T], worker: WorkerHandle) {.inline.} =
  ## Associates a `WorkerHandle` with `ch` so peer death yields `mqDetached`.
  setWorkerHandle(ch.handle, worker)

proc waitForAttach*[T](ch: ShmChannel[T]): ShmMqResult {.inline.} =
  ## Waits until the peer attaches to the other end of `ch`.
  waitForAttach(ch.handle)

proc send*[T](ch: ShmChannel[T], msg: T, nowait: bool = false,
    forceFlush: bool = true): ShmMqResult =
  ## Sends a typed POD value `msg` (`pgSizeOf[T]()` bytes) over `ch`.
  assertShmemSafe(T)
  var copyMsg = msg
  let expectedSz = pgSizeOf[T]()
  cShmMqSend(ch.handle, expectedSz, addr copyMsg, nowait, forceFlush)

proc tryReceive*[T](ch: ShmChannel[T], val: var T): ShmMqResult =
  ## Non-blocking receive into `val`. Raises `ValueError` if payload byte size
  ## does not match `pgSizeOf[T]()`.
  assertShmemSafe(T)
  let r = receiveZeroCopy(ch.handle, nowait = true)
  if r.status != mqSuccess:
    return r.status
  let expectedSz = pgSizeOf[T]()
  if r.nbytes != expectedSz:
    raise newException(ValueError,
      "ShmChannel receive size mismatch: expected " & $expectedSz &
      " bytes, got " & $r.nbytes & " bytes")
  if r.data != nil and expectedSz > 0:
    copyMem(addr val, r.data, int(expectedSz))
  return mqSuccess

proc receive*[T](ch: ShmChannel[T],
    nowait: bool = false): tuple[status: ShmMqResult, value: T] =
  ## Receives a typed POD message `T` from `ch`.
  ## Raises `ValueError` if incoming message length differs from `pgSizeOf[T]()`.
  assertShmemSafe(T)
  let r = receiveZeroCopy(ch.handle, nowait)
  if r.status != mqSuccess:
    return (status: r.status, value: default(T))
  let expectedSz = pgSizeOf[T]()
  if r.nbytes != expectedSz:
    raise newException(ValueError,
      "ShmChannel receive size mismatch: expected " & $expectedSz &
      " bytes, got " & $r.nbytes & " bytes")
  var val: T
  if r.data != nil and expectedSz > 0:
    copyMem(addr val, r.data, int(expectedSz))
  (status: mqSuccess, value: val)
