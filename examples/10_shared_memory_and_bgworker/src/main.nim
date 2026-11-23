import pgxcrown
import std/[atomics, options]

type
  Ex10SharedState* {.pgxShmem, bycopy.} = object
    workerTicks*: pg_atomic_uint64
    sqlUpdates*: int64
    lockedTotal*: int64
    lastWriter*: FixedString[16]

var
  gPragmaTicks {.pgxShared("ex10_pragma_ticks").}: Atomic[int64]
  gState: ptr Ex10SharedState = nil

proc onEx10ShmemRequest() =
  requestShmemSpace[Ex10SharedState](256.csize_t)
  requestNamedTranche("ex10_tranche", 2)

proc onEx10ShmemStartup() =
  let (st, _) = initShmemStruct[Ex10SharedState]("ex10_shared_state",
    proc(s: ptr Ex10SharedState) =
      (addr s.workerTicks).init(0'u64)
      s.sqlUpdates = 0'i64
      s.lockedTotal = 0'i64
      s.lastWriter.setStr("init")
  )
  gState = st

proc ensureEx10State(): ptr Ex10SharedState =
  if gState == nil:
    let (st, _) = initShmemStruct[Ex10SharedState]("ex10_shared_state")
    gState = st
  gState

proc ex10_init*() {.pgxInit.} =
  installShmemHooks(onEx10ShmemRequest, onEx10ShmemStartup)

proc ex10_metrics_worker*() {.pgxWorker.} =
  ## Dynamic background worker updating atomic and LWLock-protected shared memory.
  workerInit("postgres")
  let st = ensureEx10State()
  let tranche = getNamedTranche("ex10_tranche")
  runWorkerLoop(intervalMs = 40):
    workerActivity("ex10_metrics_worker tick"):
      discard gPragmaTicks[].fetchAdd(1'i64)
      if tranche != nil:
        withLock(tranche[0], lwExclusive):
          discard (addr st.workerTicks).addFetch(1'i64)
          st.lockedTotal += 1'i64
          discard st.lastWriter.trySetStr("worker")
      else:
        discard (addr st.workerTicks).addFetch(1'i64)

proc ex10_start_worker*(): int32 {.volatile.} =
  let cfg = bgWorker("ex10_metrics_worker"):
    library "10_shared_memory_and_bgworker"
    entrypoint "ex10_metrics_worker"
    database "postgres"
    restart 30
  let handle = registerDynamicWorker(cfg)
  if handle.isSome:
    let (status, pid) = handle.get.waitForStartup()
    if status == bgwStarted:
      trackWorkerStarted("ex10_metrics_worker", pid)
      return pid.int32
  -1'i32

proc ex10_stop_worker*(): bool {.volatile.} =
  stopWorkerByName("ex10_metrics_worker")

proc ex10_worker_status*(): string {.volatile.} =
  getWorkerStatusByName("ex10_metrics_worker")

proc ex10_worker_ticks*(): int64 {.volatile.} =
  let st = ensureEx10State()
  int64((addr st.workerTicks).load())

proc ex10_pragma_ticks*(): int64 {.volatile.} =
  gPragmaTicks[].load()

proc ex10_bump_shared*(delta: int64): int64 {.volatile.} =
  ## Updates shared memory from a SQL backend synchronized via LWLock tranche.
  let st = ensureEx10State()
  let tranche = getNamedTranche("ex10_tranche")
  withLock(tranche[0], lwExclusive):
    st.sqlUpdates += delta
    st.lockedTotal += delta
    discard st.lastWriter.trySetStr("sql")
    result = st.sqlUpdates

proc ex10_sql_updates*(): int64 {.volatile.} =
  let st = ensureEx10State()
  let tranche = getNamedTranche("ex10_tranche")
  withLock(tranche[0], lwShared):
    result = st.sqlUpdates

proc ex10_lwlock_invariant_ok*(): bool {.volatile.} =
  ## Verifies LWLock-protected consistency across workerTicks, sqlUpdates, and lockedTotal.
  let st = ensureEx10State()
  let tranche = getNamedTranche("ex10_tranche")
  withLock(tranche[0], lwShared):
    let ticks = int64((addr st.workerTicks).load())
    let updates = st.sqlUpdates
    let total = st.lockedTotal
    result = (total == ticks + updates) and (ticks > 0'i64) and (gPragmaTicks[].load() > 0'i64)
