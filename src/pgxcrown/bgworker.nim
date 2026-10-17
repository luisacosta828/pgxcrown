import std/[options, macros, strutils]
import ./datatypes/basic

{.passC: "-include postgres.h".}

const

  BGW_MAXLEN* = 96
  BGW_EXTRALEN* = 128

  BGWORKER_SHMEM_ACCESS* = 0x0001'i32
  BGWORKER_BACKEND_DATABASE_CONNECTION* = 0x0002'i32
  BGWORKER_CLASS_PARALLEL* = 0x0010'i32
  BGWORKER_BYPASS_ALLOWCONN* = 1'u32

  BGW_DEFAULT_RESTART_INTERVAL* = 60'i32
  BGW_NEVER_RESTART* = -1'i32

type
  BgWorkerStartTime* {.size: sizeof(cint).} = enum
    bwPostmasterStart = 0
    bwConsistentState = 1
    bwRecoveryFinished = 2

  BgwHandleStatus* {.size: sizeof(cint).} = enum
    bgwStarted = 0
    bgwNotYetStarted = 1
    bgwStopped = 2
    bgwPostmasterDied = 3

{.push header: "postmaster/bgworker.h".}

type
  BackgroundWorkerHandle* {.importc: "BackgroundWorkerHandle".} = object
  BackgroundWorkerHandlePtr* = ptr BackgroundWorkerHandle

  BackgroundWorker* {.importc: "BackgroundWorker", bycopy.} = object
    bgw_name*: array[BGW_MAXLEN, char]
    bgw_type*: array[BGW_MAXLEN, char]
    bgw_flags*: cint
    bgw_start_time*: BgWorkerStartTime
    bgw_restart_time*: cint
    bgw_library_name*: array[BGW_MAXLEN, char]
    bgw_function_name*: array[BGW_MAXLEN, char]
    bgw_main_arg*: Datum
    bgw_extra*: array[BGW_EXTRALEN, char]
    bgw_notify_pid*: cint

proc RegisterBackgroundWorker*(worker: ptr BackgroundWorker) {.importc.}
proc RegisterDynamicBackgroundWorker*(worker: ptr BackgroundWorker, handle: ptr BackgroundWorkerHandlePtr): bool {.importc.}
proc GetBackgroundWorkerPid*(handle: BackgroundWorkerHandlePtr, pid: var cint): BgwHandleStatus {.importc.}
proc WaitForBackgroundWorkerStartup*(handle: BackgroundWorkerHandlePtr, pid: var cint): BgwHandleStatus {.importc.}
proc WaitForBackgroundWorkerShutdown*(handle: BackgroundWorkerHandlePtr): BgwHandleStatus {.importc.}
proc TerminateBackgroundWorker*(handle: BackgroundWorkerHandlePtr) {.importc.}

var MyBgworkerEntry* {.importc: "MyBgworkerEntry".}: ptr BackgroundWorker

{.pop.}

var MyProcPid* {.importc, header: "miscadmin.h".}: cint


proc getWorkerExtra*(): string =
  if MyBgworkerEntry != nil and MyBgworkerEntry.bgw_extra[0] != '\0':
    return $cast[cstring](addr MyBgworkerEntry.bgw_extra[0])
  return ""

proc getWorkerName*(): string =
  if MyBgworkerEntry != nil and MyBgworkerEntry.bgw_name[0] != '\0':
    return $cast[cstring](addr MyBgworkerEntry.bgw_name[0])
  return ""

proc getWorkerType*(): string =
  if MyBgworkerEntry != nil and MyBgworkerEntry.bgw_type[0] != '\0':
    return $cast[cstring](addr MyBgworkerEntry.bgw_type[0])
  return ""

proc hasWorkerDbConnection*(): bool =
  ## Returns true if the current background worker was registered with database connection access
  MyBgworkerEntry != nil and (MyBgworkerEntry.bgw_flags and BGWORKER_BACKEND_DATABASE_CONNECTION) != 0


type
  WorkerHandle* = object
    raw*: BackgroundWorkerHandlePtr

  WorkerConfig* = object
    name*: cstring
    workerType*: cstring
    libraryName*: cstring
    functionName*: cstring
    dbName*: cstring
    userName*: cstring
    flags*: int32
    startTime*: BgWorkerStartTime
    restartIntervalSec*: int32
    mainArg*: Datum
    extra*: cstring
    notifyPid*: int32
    bypassAllowConn*: bool

macro bgWorker*(workerName: untyped, body: untyped = nil): untyped =
  let b = genSym(nskVar, "workerConfig")
  let nameSym = genSym(nskLet, "nameVal")
  var initStmts = newStmtList()
  initStmts.add quote do:
    let `nameSym` = `workerName`
    var `b`: WorkerConfig
    `b`.name = cstring(`nameSym`)
    `b`.workerType = cstring(`nameSym`)
    `b`.libraryName = cstring(`nameSym`)
    `b`.functionName = cstring(`nameSym` & "_worker")
    `b`.flags = BGWORKER_SHMEM_ACCESS
    `b`.startTime = bwRecoveryFinished
    `b`.restartIntervalSec = BGW_NEVER_RESTART

  if body != nil and body.kind != nnkNilLit:
    if body.kind != nnkStmtList:
      initStmts.add quote do:
        `b`.functionName = cstring(`body`)
    else:
      for stmt in body:
        if stmt.kind in {nnkCall, nnkCommand} and stmt.len >= 2:
          let directive = stmt[0].repr.strip
          let val = stmt[1]
          case directive
          of "entrypoint", "function", "functionName":
            initStmts.add quote do: `b`.functionName = cstring(`val`)
          of "database", "db", "dbName":
            initStmts.add quote do:
              `b`.dbName = cstring(`val`)
              `b`.flags = `b`.flags or BGWORKER_BACKEND_DATABASE_CONNECTION
          of "user", "userName":
            initStmts.add quote do: `b`.userName = cstring(`val`)
          of "library", "lib", "libraryName":
            initStmts.add quote do: `b`.libraryName = cstring(`val`)
          of "workerType", "type":
            initStmts.add quote do: `b`.workerType = cstring(`val`)
          of "restart", "restartInterval", "restartIntervalSec":
            initStmts.add quote do: `b`.restartIntervalSec = int32(`val`)
          of "mainArg", "arg":
            initStmts.add quote do: `b`.mainArg = cast[Datum](`val`)
          of "extra":
            initStmts.add quote do: `b`.extra = cstring(`val`)
          of "notifyPid":
            initStmts.add quote do: `b`.notifyPid = int32(`val`)
          of "flags":
            initStmts.add quote do: `b`.flags = int32(`val`)
          of "startTime":
            initStmts.add quote do: `b`.startTime = `val`
          of "bypassAllowConn":
            initStmts.add quote do: `b`.bypassAllowConn = bool(`val`)
          else:
            initStmts.add stmt
        elif stmt.kind == nnkIdent:
          let directive = stmt.repr.strip
          case directive
          of "bypassAllowConn":
            initStmts.add quote do: `b`.bypassAllowConn = true
          else:
            initStmts.add stmt
        else:
          initStmts.add stmt

  initStmts.add quote do:
    `b`

  result = newTree(nnkStmtListExpr, initStmts)


proc copyToFixed[N: static int](dest: var array[N, char], src: cstring) {.inline.} =
  if src != nil and src[0] != '\0':
    copyMem(addr dest[0], src, min(src.len, N - 1))

proc toRawWorker*(cfg: WorkerConfig): BackgroundWorker =
  copyToFixed(result.bgw_name, cfg.name)
  copyToFixed(result.bgw_type, cfg.workerType)
  result.bgw_flags = cint(cfg.flags)
  result.bgw_start_time = cfg.startTime
  result.bgw_restart_time = cint(cfg.restartIntervalSec)
  copyToFixed(result.bgw_library_name, cfg.libraryName)
  copyToFixed(result.bgw_function_name, cfg.functionName)
  result.bgw_main_arg = cfg.mainArg
  copyToFixed(result.bgw_extra, cfg.extra)
  result.bgw_notify_pid = cint(cfg.notifyPid)

proc registerWorker*(cfg: WorkerConfig) =
  var raw = cfg.toRawWorker()
  RegisterBackgroundWorker(addr raw)

proc registerDynamicWorker*(cfg: WorkerConfig): Option[WorkerHandle] =
  var raw = cfg.toRawWorker()
  if raw.bgw_notify_pid == 0:
    raw.bgw_notify_pid = MyProcPid

  var handlePtr: BackgroundWorkerHandlePtr = nil

  let ok = RegisterDynamicBackgroundWorker(addr raw, addr handlePtr)
  if ok and handlePtr != nil:
    return some(WorkerHandle(raw: handlePtr))
  return none(WorkerHandle)

proc waitForStartup*(handle: WorkerHandle): (BgwHandleStatus, int) =
  if handle.raw == nil:
    return (bgwStopped, -1)
  var pid: cint = 0
  let status = WaitForBackgroundWorkerStartup(handle.raw, pid)
  return (status, pid.int)

proc waitForShutdown*(handle: WorkerHandle): BgwHandleStatus =
  if handle.raw == nil:
    return bgwStopped
  return WaitForBackgroundWorkerShutdown(handle.raw)

proc getPid*(handle: WorkerHandle): (BgwHandleStatus, int) =
  if handle.raw == nil:
    return (bgwStopped, -1)
  var pid: cint = 0
  let status = GetBackgroundWorkerPid(handle.raw, pid)
  return (status, pid.int)

proc terminate*(handle: WorkerHandle) =
  if handle.raw != nil:
    TerminateBackgroundWorker(handle.raw)

import std/volatile
import ./reports/reports
import ./query_builder
import ./spi
export spi.subTransaction, spi.savepoint

type
  BackendState* {.size: sizeof(cint).} = enum
    stateUndefined = 0
    stateIdle = 1
    stateRunning = 2
    stateIdleInTransaction = 3
    stateFastpath = 4
    stateIdleInTransactionAborted = 5
    stateDisabled = 6

proc pgstat_report_activity*(state: BackendState, cmd_str: cstring) {.importc, header: "utils/backend_status.h".}

proc setWorkerActivity*(activity: string, state: BackendState = stateRunning) =
  ## Updates the current worker activity in pg_stat_activity (query and state columns)
  if activity.len == 0:
    pgstat_report_activity(state, nil)
  else:
    pgstat_report_activity(state, cstring(activity))

proc setWorkerIdle*(msg: string = "idle (waiting)") =
  ## Marks the worker as idle in pg_stat_activity
  pgstat_report_activity(stateIdle, cstring(msg))

template workerActivity*(activity: string, body: untyped) =
  ## Scoped block: sets worker activity in pg_stat_activity while executing body,
  ## and restores idle status upon completion.
  setWorkerActivity(activity, stateRunning)
  try:
    body
  finally:
    setWorkerIdle()

template workerSavepoint*(body: untyped, onError: untyped) =
  ## Alias for savepoint in worker transaction loops
  savepoint(body, onError)

# =============================================================================
# Worker Registry & Catalog Tracking (pgxcrown_workers)
# =============================================================================

proc ensureWorkersCatalog*() =
  ## Ensures the tracking table pgxcrown_workers exists
  spi_init:
    pgTry:
      let ddl = "CREATE TABLE IF NOT EXISTS pgxcrown_workers (" &
                "name TEXT PRIMARY KEY, " &
                "pid INT NOT NULL, " &
                "started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), " &
                "status TEXT NOT NULL, " &
                "last_seen TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());"
      discard exec(const_string(ddl), 0)

proc trackWorkerStarted*(name: string, pid: int) =
  ## Registers or updates the worker in pgxcrown_workers
  ensureWorkersCatalog()
  spi_init:
    pgTry:
      let q = "INSERT INTO pgxcrown_workers (name, pid, started_at, status, last_seen) " &
              "VALUES (" & quoteLiteral(name) & ", " & $pid & ", clock_timestamp(), 'running', clock_timestamp()) " &
              "ON CONFLICT (name) DO UPDATE SET " &
              "pid = EXCLUDED.pid, started_at = EXCLUDED.started_at, " &
              "status = 'running', last_seen = clock_timestamp();"
      discard exec(const_string(q), 0)

proc trackWorkerStopped*(name: string) =
  ## Marks the worker as stopped in pgxcrown_workers
  ensureWorkersCatalog()
  spi_init:
    pgTry:
      let q = "UPDATE pgxcrown_workers SET status = 'stopped', last_seen = clock_timestamp() " &
              "WHERE name = " & quoteLiteral(name) & ";"
      discard exec(const_string(q), 0)

proc stopWorkerByName*(name: string): bool =
  ## Terminates a worker by name via pg_terminate_backend and marks it stopped
  ensureWorkersCatalog()
  var targetPid = 0
  let findQ = "SELECT pid FROM pgxcrown_workers WHERE name = " & quoteLiteral(name) & " AND status = 'running';"
  let rows = fetchRawRows(findQ)
  if rows.len > 0 and "pid" in rows[0]:
    try:
      targetPid = parseInt(rows[0]["pid"])
    except ValueError:
      targetPid = 0

  if targetPid > 0:
    let termQ = "SELECT pg_terminate_backend(" & $targetPid & ");"
    discard fetchRawRows(termQ)
    trackWorkerStopped(name)
    return true
  return false

proc getWorkerStatusByName*(name: string): string =
  ## Returns the live status of the worker ('running', 'stopped', or 'not_registered')
  ensureWorkersCatalog()
  var recordedStatus = ""
  var targetPid = 0
  let q = "SELECT pid, status FROM pgxcrown_workers WHERE name = " & quoteLiteral(name) & ";"
  let rows = fetchRawRows(q)
  if rows.len > 0:
    recordedStatus = rows[0].getOrDefault("status", "")
    try:
      targetPid = parseInt(rows[0].getOrDefault("pid", "0"))
    except ValueError:
      targetPid = 0

  if recordedStatus == "":
    return "not_registered"
  if recordedStatus == "stopped":
    return "stopped"

  # If recorded as running, check if process is actually alive in pg_stat_activity
  var isAlive = false
  if targetPid > 0:
    let checkQ = "SELECT 1 FROM pg_stat_activity WHERE pid = " & $targetPid & ";"
    let checkRows = fetchRawRows(checkQ)
    if checkRows.len > 0:
      isAlive = true

  if isAlive:
    return "running"
  else:
    trackWorkerStopped(name)
    return "stopped"

const
  WL_LATCH_SET* = 1'i32 shl 0          # 0x01
  WL_TIMEOUT* = 1'i32 shl 3            # 0x08 (storage/latch.h:128)
  WL_POSTMASTER_DEATH* = 1'i32 shl 4   # 0x10 (storage/latch.h:129)
  WL_EXIT_ON_PM_DEATH* = 1'i32 shl 5   # 0x20 (storage/latch.h:130)
  PG_WAIT_EXTENSION* = 0x07000000'u32  # utils/wait_event.h:23
  PGC_SIGHUP* = 2'i32                  # utils/guc.h:72

  SIGTERM* = 15'i32
  SIGHUP* = 1'i32

type
  SigAtomic* {.importc: "sig_atomic_t", header: "signal.h".} = cint

var MyLatch* {.importc, header: "miscadmin.h".}: pointer
var posixErrno {.importc: "errno", header: "errno.h".}: cint




proc BackgroundWorkerUnblockSignals*() {.importc, header: "postmaster/bgworker.h".}
proc BackgroundWorkerInitializeConnection*(dbname, username: cstring, flags: cuint) {.importc, header: "postmaster/bgworker.h".}

proc SetCurrentStatementStartTimestamp*() {.importc, header: "access/xact.h".}
proc StartTransactionCommand*() {.importc, header: "access/xact.h".}
proc CommitTransactionCommand*() {.importc, header: "access/xact.h".}
proc AbortCurrentTransaction*() {.importc, header: "access/xact.h".}

type
  PgSnapshot* {.importc: "Snapshot", header: "utils/snapmgr.h".} = pointer

proc GetTransactionSnapshot*(): PgSnapshot {.importc, header: "utils/snapmgr.h".}
proc PushActiveSnapshot*(snapshot: PgSnapshot) {.importc, header: "utils/snapmgr.h".}
proc PopActiveSnapshot*() {.importc, header: "utils/snapmgr.h".}
proc ActiveSnapshotSet*(): bool {.importc, header: "utils/snapmgr.h".}


proc WaitLatch*(latch: pointer, wakeEvents: cint, timeout_ms: clong, wait_event_info: uint32): cint {.importc, header: "storage/latch.h".}
proc ResetLatch*(latch: pointer) {.importc, header: "storage/latch.h".}
proc SetLatch*(latch: pointer) {.importc, header: "storage/latch.h".}

proc proc_exit*(code: cint) {.importc: "proc_exit".}
proc ProcessConfigFile*(context: cint) {.importc, header: "utils/guc.h".}
proc pqsignal*(signo: cint, handler: proc(signo: cint) {.cdecl.}): pointer {.importc, header: "libpq/pqsignal.h".}

var workerGotSigterm* {.exportc: "pgx_worker_got_sigterm", volatile.}: SigAtomic = 0
var workerGotSighup* {.exportc: "pgx_worker_got_sighup", volatile.}: SigAtomic = 0

proc isWorkerSigtermSet*(): bool =
  volatileLoad(addr workerGotSigterm) != 0

proc setWorkerSigterm*(val: SigAtomic = 1) =
  volatileStore(addr workerGotSigterm, val)

proc consumeWorkerSighup*(): bool =
  if volatileLoad(addr workerGotSighup) != 0:
    volatileStore(addr workerGotSighup, 0)
    return true
  return false

proc onSigterm(signo: cint) {.cdecl.} =
  let saved = posixErrno
  volatileStore(addr workerGotSigterm, 1)
  if MyLatch != nil:
    SetLatch(MyLatch)
  posixErrno = saved

proc onSighup(signo: cint) {.cdecl.} =
  let saved = posixErrno
  volatileStore(addr workerGotSighup, 1)
  if MyLatch != nil:
    SetLatch(MyLatch)
  posixErrno = saved

proc setupSignals*() =
  volatileStore(addr workerGotSigterm, 0)
  volatileStore(addr workerGotSighup, 0)
  discard pqsignal(SIGTERM, onSigterm)
  discard pqsignal(SIGHUP, onSighup)

proc workerInit*(dbName: cstring = nil, userName: cstring = nil, bypassAllowConn: bool = false) =
  setupSignals()
  BackgroundWorkerUnblockSignals()
  if dbName != nil and dbName[0] != '\0':
    let flags: cuint = if bypassAllowConn: cuint(BGWORKER_BYPASS_ALLOWCONN) else: 0'u32
    BackgroundWorkerInitializeConnection(dbName, userName, flags)

proc workerExit*(code: int = 0) {.inline.} =
  proc_exit(cint(code))

template workerTransaction*(body: untyped) =
  SetCurrentStatementStartTimestamp()
  StartTransactionCommand()
  PushActiveSnapshot(GetTransactionSnapshot())
  try:
    body
    PopActiveSnapshot()
    CommitTransactionCommand()
  except CatchableError as e:
    if ActiveSnapshotSet():
      PopActiveSnapshot()
    AbortCurrentTransaction()
    raise e
  except Defect as e:
    if ActiveSnapshotSet():
      PopActiveSnapshot()
    AbortCurrentTransaction()
    raise e


template runWorkerLoop*(intervalMs: int, body: untyped, shutdownHandler: untyped) =
  if MyLatch != nil:
    ResetLatch(MyLatch)
  while not isWorkerSigtermSet():
    if consumeWorkerSighup():
      ProcessConfigFile(PGC_SIGHUP)
    try:
      body
    except CatchableError as err:
      pgWarning("BgWorker error: " & err.msg)
    except Defect as defect:
      pgWarning("BgWorker defect: " & defect.msg)
    if isWorkerSigtermSet():
      break
    setWorkerIdle("waiting for next cycle (" & $intervalMs & "ms)")
    if MyLatch != nil:
      ResetLatch(MyLatch)
    let rc = WaitLatch(MyLatch, WL_LATCH_SET or WL_TIMEOUT or WL_POSTMASTER_DEATH, clong(intervalMs), PG_WAIT_EXTENSION)
    if MyLatch != nil:
      ResetLatch(MyLatch)
    if (rc and WL_POSTMASTER_DEATH) != 0:
      workerExit(1)

  # Graceful shutdown: auto-update catalog (only when connected to a database) and execute shutdown handler
  let wName = getWorkerName()
  if wName.len > 0 and hasWorkerDbConnection():
    try:
      workerTransaction:
        trackWorkerStopped(wName)
    except CatchableError:
      discard
    except Defect:
      discard

  try:
    shutdownHandler
  except CatchableError as err:
    pgWarning("BgWorker shutdown error: " & err.msg)
  except Defect as defect:
    pgWarning("BgWorker shutdown defect: " & defect.msg)
  setWorkerIdle("stopped")
  workerExit(0)

template runWorkerLoop*(intervalMs: int, body: untyped) =
  runWorkerLoop(intervalMs, body):
    discard
