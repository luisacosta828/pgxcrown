import std/[posix, strutils, options]
import pgxcrown

const
  IPC_TOC_MAGIC = 0x49504331'u64
  KEY_STATE = 1'u64
  KEY_REQ_MQ = 2'u64
  KEY_RESP_MQ = 3'u64
  QUEUE_BYTES = 8192.csize_t

type
  IpcSharedState* {.pgxShmem, bycopy.} = object
    trancheId*: cint
    lock*: LWLock
    processedCount*: pg_atomic_uint32
    socketPings*: pg_atomic_uint32
    lastReply*: FixedString[64]

  IpcTypedReq* {.pgxShared.} = object
    a*: int64
    b*: int64
    label*: FixedString[24]

  IpcTypedResp* {.pgxShared.} = object
    sum*: int64
    product*: int64
    label*: FixedString[24]

proc ipc_typed_worker*() {.pgxWorker.} =
  workerInit()
  ensureResourceOwner("ipc_typed_worker")

  let handle = DsmHandle(MyBgworkerEntry.bgw_main_arg)
  let seg = dsmAttachOrFind(handle)
  if seg == nil:
    workerExit(1)

  let toc = attachToc(seg, IPC_TOC_MAGIC)
  let rpc = lookupRpcQueues(toc, KEY_REQ_MQ, KEY_RESP_MQ)
  var reqCh = openRecvChannel[IpcTypedReq](rpc.reqMq, seg)
  var respCh = openSendChannel[IpcTypedResp](rpc.respMq, seg)

  while not isWorkerSigtermSet():
    if MyLatch != nil:
      ResetLatch(MyLatch)
    CHECK_FOR_INTERRUPTS()
    if isWorkerSigtermSet():
      break
    let got = reqCh.receive(nowait = false)
    if got.status == mqDetached:
      break
    if got.status == mqSuccess:
      var resp: IpcTypedResp
      resp.sum = got.value.a + got.value.b
      resp.product = got.value.a * got.value.b
      resp.label.setStr("ok:" & $got.value.label)
      if respCh.send(resp) == mqDetached:
        break

  respCh.close()
  reqCh.close()
  dsmDetach(seg)
  workerExit(0)

proc ipc_rpc_worker*() {.pgxWorker.} =
  workerInit()
  ensureResourceOwner("ipc_dsm_worker")

  let handle = DsmHandle(MyBgworkerEntry.bgw_main_arg)
  let seg = dsmAttachOrFind(handle)
  if seg == nil:
    workerExit(1)

  let toc = attachToc(seg, IPC_TOC_MAGIC)
  let st = lookupStruct[IpcSharedState](toc, KEY_STATE)
  let rpc = lookupRpcQueues(toc, KEY_REQ_MQ, KEY_RESP_MQ)

  registerTrancheCopy(st.trancheId, "pgx_ipc_dsm")

  rpc.reqMq.setReceiver(myProc())
  rpc.respMq.setSender(myProc())

  let reqH = attachMq(rpc.reqMq, seg)
  let respH = attachMq(rpc.respMq, seg)

  var fds: array[2, cint] = [-1.cint, -1.cint]
  if socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0:
    discard setSocketNonBlocking(fds[0])
    discard setSocketNonBlocking(fds[1])
    var pingByte: uint8 = 0x50'u8
    discard posix.write(fds[1], addr pingByte, 1)

  withWaitEventSet(wes, 3):
    discard wes.addLatchEvent(MyLatch)
    discard wes.addPostmasterDeathEvent(exitOnDeath = true)
    if fds[0] >= 0:
      discard wes.addSocketEvent(fds[0], WL_SOCKET_READABLE or wlSocketClosed())

    var occurred: array[4, WaitEvent]
    while not isWorkerSigtermSet():
      if MyLatch != nil:
        ResetLatch(MyLatch)
      CHECK_FOR_INTERRUPTS()
      if isWorkerSigtermSet():
        break

      let nEvents = wes.waitEventSet(250, occurred)
      for i in 0 ..< nEvents:
        let ev = occurred[i]
        if (ev.events and uint32(WL_POSTMASTER_DEATH)) != 0:
          workerExit(1)
        if fds[0] >= 0 and ev.fd == fds[0] and (ev.events and WL_SOCKET_READABLE) != 0:
          var buf: array[16, uint8]
          while true:
            let nRead = posix.read(fds[0], addr buf[0], buf.len)
            if nRead > 0:
              discard (addr st.socketPings).addFetch(1)
            else:
              break

      var detached = false
      while not isWorkerSigtermSet():
        let got = reqH.receive(nowait = true)
        case got.status
        of mqSuccess:
          let reply = "echo:" & got.payload.toUpperAscii()
          withLock(addr st.lock, lwExclusive):
            discard (addr st.processedCount).addFetch(1)
            st.lastReply.setStr(reply)
          if respH.send(reply) == mqDetached:
            detached = true
            break
        of mqWouldBlock:
          break
        of mqDetached:
          detached = true
          break

      if detached:
        break

  if fds[0] >= 0:
    discard posix.close(fds[0])
  if fds[1] >= 0:
    discard posix.close(fds[1])
  detachMq(respH)
  detachMq(reqH)
  dsmDetach(seg)
  workerExit(0)

proc ipc_rpc_roundtrip*(msg: string): string {.volatile.} =
  var est = initEstimator()
  est.estimateChunk(pgSizeOf[IpcSharedState]())
  est.estimateKeys(1)
  est.estimateRpcQueues(QUEUE_BYTES, QUEUE_BYTES)

  let seg = dsmCreate(est.estimate())
  if seg == nil:
    raise newException(ValueError, "dsmCreate returned nil")

  var reqH: ShmMqHandlePtr = nil
  var respH: ShmMqHandlePtr = nil
  var workerOpt: Option[WorkerHandle] = none(WorkerHandle)

  try:
    let toc = createToc(seg, IPC_TOC_MAGIC)
    let st = allocStruct[IpcSharedState](toc, KEY_STATE)
    let tid = newTrancheId()
    registerTrancheCopy(tid, "pgx_ipc_dsm")
    st.trancheId = tid
    (addr st.lock).init(tid)
    (addr st.processedCount).init(0'u32)
    (addr st.socketPings).init(0'u32)
    st.lastReply.setStr("")

    let rpc = createRpcQueues(toc, KEY_REQ_MQ, KEY_RESP_MQ, QUEUE_BYTES, QUEUE_BYTES)
    rpc.reqMq.setSender(myProc())
    rpc.respMq.setReceiver(myProc())

    let cfg = bgWorker("ipc_dsm_suite"):
      entrypoint "ipc_rpc_worker"
      mainArg dsmHandle(seg)

    workerOpt = registerDynamicWorker(cfg)
    if workerOpt.isNone:
      raise newException(ValueError, "registerDynamicWorker failed")
    let wh = workerOpt.get()
    let (status, _) = wh.waitForStartup()
    if status != bgwStarted:
      raise newException(ValueError, "dynamic worker failed to start")

    reqH = attachMq(rpc.reqMq, seg, wh)
    respH = attachMq(rpc.respMq, seg, wh)

    let sendRes = reqH.send($msg)
    if sendRes != mqSuccess:
      raise newException(ValueError, "shm_mq send failed")

    let recvRes = respH.receive()
    if recvRes.status != mqSuccess:
      raise newException(ValueError, "shm_mq receive failed")

    detachMq(reqH)
    reqH = nil
    detachMq(respH)
    respH = nil

    wh.terminate()
    discard wh.waitForShutdown()

    var cnt: uint32 = 0
    var sp: uint32 = 0
    var storedReply = ""
    withLock(addr st.lock, lwShared):
      cnt = (addr st.processedCount).load()
      sp = (addr st.socketPings).load()
      storedReply = $st.lastReply

    result = "reply=" & recvRes.payload & "|stored=" & storedReply &
             "|count=" & $cnt & "|sock=" & $sp
  finally:
    if reqH != nil:
      detachMq(reqH)
    if respH != nil:
      detachMq(respH)
    if workerOpt.isSome:
      workerOpt.get().terminate()
      discard workerOpt.get().waitForShutdown()
    dsmDetach(seg)

proc ipc_typed_channel_roundtrip*(a: int64, b: int64, label: string): string {.volatile.} =
  var est = initEstimator()
  est.estimateRpcQueues(QUEUE_BYTES, QUEUE_BYTES)

  let seg = dsmCreate(est.estimate())
  if seg == nil:
    raise newException(ValueError, "dsmCreate returned nil")

  var reqCh: ShmChannel[IpcTypedReq]
  var respCh: ShmChannel[IpcTypedResp]
  var workerOpt: Option[WorkerHandle] = none(WorkerHandle)

  try:
    let toc = createToc(seg, IPC_TOC_MAGIC)
    let rpc = createRpcQueues(toc, KEY_REQ_MQ, KEY_RESP_MQ, QUEUE_BYTES, QUEUE_BYTES)

    let cfg = bgWorker("ipc_dsm_suite"):
      entrypoint "ipc_typed_worker"
      mainArg dsmHandle(seg)

    workerOpt = registerDynamicWorker(cfg)
    if workerOpt.isNone:
      raise newException(ValueError, "registerDynamicWorker failed")
    let wh = workerOpt.get()
    let (status, _) = wh.waitForStartup()
    if status != bgwStarted:
      raise newException(ValueError, "dynamic worker failed to start")

    reqCh = openSendChannel[IpcTypedReq](rpc.reqMq, seg, wh)
    respCh = openRecvChannel[IpcTypedResp](rpc.respMq, seg, wh)

    var req: IpcTypedReq
    req.a = a
    req.b = b
    req.label.setStr($label)
    if reqCh.send(req) != mqSuccess:
      raise newException(ValueError, "ShmChannel[IpcTypedReq] send failed")

    let got = respCh.receive()
    if got.status != mqSuccess:
      raise newException(ValueError, "ShmChannel[IpcTypedResp] receive failed")

    reqCh.close()
    respCh.close()
    wh.terminate()
    discard wh.waitForShutdown()

    result = $got.value.label & "|sum=" & $got.value.sum & "|prod=" & $got.value.product
  finally:
    reqCh.close()
    respCh.close()
    if workerOpt.isSome:
      workerOpt.get().terminate()
      discard workerOpt.get().waitForShutdown()
    dsmDetach(seg)

proc ipc_sugar_worker*(req: IpcTypedReq): IpcTypedResp {.pgxWorker.} =
  result.sum = req.a + req.b
  result.product = req.a * req.b
  result.label.setStr("sugar:" & $req.label)

proc ipc_sugar_call*(a: int64, b: int64, label: string): string {.volatile.} =
  var req: IpcTypedReq
  req.a = a
  req.b = b
  req.label.setStr($label)
  let r1 = callWorker[IpcTypedResp]("ipc_dsm_suite", "ipc_sugar_worker", req)
  var sumBatch: int64 = 0
  withWorkerChannel(ch, IpcTypedReq, IpcTypedResp, "ipc_dsm_suite", "ipc_sugar_worker"):
    var req2 = req
    req2.a = a + 1
    sumBatch = ch.call(req).sum + ch.call(req2).sum
  result = $r1.label & "|sum=" & $r1.sum & "|prod=" & $r1.product & "|batch=" & $sumBatch
