import pgxcrown

type
  PreloadBenchState* {.pgxShmem, bycopy.} = object
    hits*: pg_atomic_uint64
    workerTicks*: pg_atomic_uint64
    cv*: ConditionVariable
    banner*: FixedString[32]

  PragmaSharedMetrics* {.pgxShared.} = object
    requests*: pg_atomic_uint64
    tag*: FixedString[24]

proc initPragmaMetrics(p: ptr PragmaSharedMetrics) =
  (addr p.requests).init(100'u64)
  p.tag.setStr("pragma_shared_ok")

var pragmaMetrics* {.pgxShared("pgx_pragma_metrics", initPragmaMetrics).}: PragmaSharedMetrics

var
  gState: ptr PreloadBenchState = nil

proc onPreloadShmemRequest() =
  requestShmemSpace[PreloadBenchState](256.csize_t)
  requestNamedTranche("pgx_preload_suite", 2)

proc onPreloadShmemStartup() =
  let (st, _) = initShmemStruct[PreloadBenchState]("pgxcrown_preload_state",
    proc(s: ptr PreloadBenchState) =
      (addr s.hits).init(0'u64)
      (addr s.workerTicks).init(0'u64)
      (addr s.cv).init()
      s.banner.setStr("pgxcrown_preload_ready")
  )
  gState = st

proc ensurePreloadState(): ptr PreloadBenchState =
  if gState == nil:
    let (st, _) = initShmemStruct[PreloadBenchState]("pgxcrown_preload_state")
    gState = st
  return gState

proc preload_ticker_worker*() {.pgxWorker.} =
  workerInit()
  let st = ensurePreloadState()
  let tranche = getNamedTranche("pgx_preload_suite")
  runWorkerLoop(intervalMs = 40):
    if tranche != nil:
      withLock(tranche[0]):
        discard (addr st.workerTicks).addFetch(1)
    else:
      discard (addr st.workerTicks).addFetch(1)
    (addr st.cv).broadcast()

proc shmem_preload_init*() {.pgxInit.} =
  installShmemHooks(onPreloadShmemRequest, onPreloadShmemStartup)
  let cfg = bgWorker("shmem_preload_suite"):
    entrypoint "preload_ticker_worker"
    startTime bwRecoveryFinished
    restart 1
  registerWorker(cfg)

proc shmem_banner*(): string {.volatile.} =
  let st = ensurePreloadState()
  let tranche = getNamedTranche("pgx_preload_suite")
  withLock(tranche[1], lwShared):
    result = $st.banner

proc shmem_bump_hits*(delta: int64): int64 {.volatile.} =
  let st = ensurePreloadState()
  let tranche = getNamedTranche("pgx_preload_suite")
  withLock(tranche[0], lwExclusive):
    result = int64((addr st.hits).addFetch(delta))

proc shmem_await_ticks*(minTicks: int64, timeoutMs: int64): bool {.volatile.} =
  let st = ensurePreloadState()
  let tranche = getNamedTranche("pgx_preload_suite")
  result = waitUntil(addr st.cv, tranche[0], lwShared, timeoutMs, PGX_WAIT_EXTENSION):
    int64((addr st.workerTicks).load()) >= minTicks

proc shmem_worker_ticks*(): int64 {.volatile.} =
  let st = ensurePreloadState()
  result = int64((addr st.workerTicks).load())

proc shmem_pragma_bump*(delta: int64): string {.volatile.} =
  let val = (addr pragmaMetrics.requests).addFetch(delta)
  result = $pragmaMetrics.tag & ":" & $val
