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

proc GetTransactionSnapshot*(): pointer {.importc, header: "utils/snapmgr.h".}
proc PushActiveSnapshot*(snapshot: pointer) {.importc, header: "utils/snapmgr.h".}
proc PopActiveSnapshot*() {.importc, header: "utils/snapmgr.h".}
proc ActiveSnapshotSet*(): bool {.importc, header: "utils/snapmgr.h".}


proc WaitLatch*(latch: pointer, wakeEvents: cint, timeout_ms: clong, wait_event_info: uint32): cint {.importc, header: "storage/latch.h".}
proc ResetLatch*(latch: pointer) {.importc, header: "storage/latch.h".}
proc SetLatch*(latch: pointer) {.importc, header: "storage/latch.h".}

proc proc_exit*(code: cint) {.importc, header: "storage/ipc.h".}
proc ProcessConfigFile*(context: cint) {.importc, header: "utils/guc.h".}
proc pqsignal*(signo: cint, handler: proc(signo: cint) {.cdecl.}): pointer {.importc, header: "libpq/pqsignal.h".}

var workerGotSigterm* {.volatile.}: SigAtomic = 0
var workerGotSighup* {.volatile.}: SigAtomic = 0

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


template runWorkerLoop*(intervalMs: int, body: untyped) =
  while volatileLoad(addr workerGotSigterm) == 0:
    if volatileLoad(addr workerGotSighup) != 0:
      volatileStore(addr workerGotSighup, 0)
      ProcessConfigFile(PGC_SIGHUP)
    try:
      body
    except CatchableError as err:
      pgWarning("BgWorker error: " & err.msg)
    except Defect as defect:
      pgWarning("BgWorker defect: " & defect.msg)
    if volatileLoad(addr workerGotSigterm) != 0:
      break
    let rc = WaitLatch(MyLatch, WL_LATCH_SET or WL_TIMEOUT or WL_POSTMASTER_DEATH, clong(intervalMs), PG_WAIT_EXTENSION)
    ResetLatch(MyLatch)
    if (rc and WL_POSTMASTER_DEATH) != 0:
      workerExit(1)
  workerExit(0)
