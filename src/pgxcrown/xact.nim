## =============================================================================
## Pgxcrown PostgreSQL Transaction & Subtransaction Lifecycle Callbacks
## =============================================================================
## Provides process-lifetime safe bindings for PostgreSQL's `RegisterXactCallback`
## and `RegisterSubXactCallback`:
##   - Exact PG 14-18 `XactEvent` and `SubXactEvent` C-ABI enum ordinals
##   - Libc-backed callback storage immune to PostgreSQL `MemoryContextReset`
##   - Re-entrancy-safe registration and unregistration during callback dispatch
##   - Anti-PANIC shield: post-commit, abort, prepare, and subxact-start/end phases
##     catch all Nim `CatchableError`, `Defect`, and PostgreSQL `ERROR`s and emit
##     a safe `WARNING` instead of crashing PostgreSQL with `PANIC`
##   - Controlled `ERROR` translation for `xePreCommit`, `xeParallelPreCommit`,
##     `xePrePrepare`, and `sxePreCommitSub`
##
## Note on capturing closures created inside SQL UDFs:
##   When registering a capturing closure from inside a SQL-callable UDF (where
##   `CurrentMemoryContext` is a short-lived `ExprContext` or `SPI Proc`), construct
##   the closure inside a helper proc invoked under `pgxWithLibcAlloc:` so Nim's
##   closure environment and captured heap values live in process-lifetime libc
##   memory rather than the transient `ExprContext`.
## =============================================================================

import std/os
import ./compiler
import ./allocator
import ./reports/reports

const PgxXactCHeadersDir = currentSourcePath.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxXactCHeadersDir).}

type
  XactEvent* {.size: sizeof(cint).} = enum
    ## PostgreSQL top-level transaction callback events (`access/xact.h`).
    xeCommit = 0
    xeParallelCommit = 1
    xeAbort = 2
    xeParallelAbort = 3
    xePrepare = 4
    xePreCommit = 5
    xeParallelPreCommit = 6
    xePrePrepare = 7

  SubXactEvent* {.size: sizeof(cint).} = enum
    ## PostgreSQL subtransaction callback events (`access/xact.h`).
    sxeStartSub = 0
    sxeCommitSub = 1
    sxeAbortSub = 2
    sxePreCommitSub = 3

  SubTransactionId* = uint32

  XactCallbackProc* = proc(event: XactEvent) {.closure.}
  SubXactCallbackProc* = proc(event: SubXactEvent, mySubid: SubTransactionId,
                              parentSubid: SubTransactionId) {.closure.}
  XactSimpleProc* = proc() {.closure.}
  SubXactSimpleProc* = proc(mySubid: SubTransactionId,
                            parentSubid: SubTransactionId) {.closure.}

  XactHandle* = distinct uint64
  SubXactHandle* = distinct uint64

const
  InvalidSubTransactionId* = SubTransactionId(0)
  TopSubTransactionId* = SubTransactionId(1)
  InvalidXactHandle* = XactHandle(0)
  InvalidSubXactHandle* = SubXactHandle(0)

proc `==`*(a, b: XactHandle): bool {.borrow.}
proc `==`*(a, b: SubXactHandle): bool {.borrow.}
proc `$`*(h: XactHandle): string {.inline.} = "XactHandle(" & $uint64(h) & ")"
proc `$`*(h: SubXactHandle): string {.inline.} = "SubXactHandle(" & $uint64(h) & ")"
proc isValid*(h: XactHandle): bool {.inline.} = uint64(h) != 0'u64
proc isValid*(h: SubXactHandle): bool {.inline.} = uint64(h) != 0'u64

proc isErrorableXactEvent*(event: XactEvent): bool {.inline.} =
  ## Returns true for pre-commit / pre-prepare phases where PostgreSQL permits
  ## raising a controlled `ERROR` to abort the transaction cleanly.
  event in {xePreCommit, xeParallelPreCommit, xePrePrepare}

proc isErrorableSubXactEvent*(event: SubXactEvent): bool {.inline.} =
  ## Returns true for `sxePreCommitSub`, where PostgreSQL permits raising a
  ## controlled `ERROR` before the subtransaction commits.
  event == sxePreCommitSub

type
  PgxXactCDispatchFn = proc(rawEvent: cint, arg: pointer) {.cdecl.}
  PgxSubXactCDispatchFn = proc(rawEvent: cint, mySubid: cuint, parentSubid: cuint,
                               arg: pointer) {.cdecl.}

{.push header: "pgx_xact.h".}
proc pgxPushLibcAlloc*() {.importc: "pgx_push_libc_alloc".}
proc pgxPopLibcAlloc*() {.importc: "pgx_pop_libc_alloc".}
proc pgxSetXactDispatcherRaw(fn: PgxXactCDispatchFn) {.importc: "pgx_set_xact_dispatcher".}
proc pgxSetSubXactDispatcherRaw(fn: PgxSubXactCDispatchFn) {.importc: "pgx_set_subxact_dispatcher".}
proc pgxEnsureXactRegisteredRaw() {.importc: "pgx_ensure_xact_registered".}
proc pgxEnsureSubXactRegisteredRaw() {.importc: "pgx_ensure_subxact_registered".}
proc pgxXactEmitWarningRaw(msg: cstring) {.importc: "pgx_xact_emit_warning".}
proc pgxCurrentSubXactIdRaw(): SubTransactionId {.importc: "pgx_current_subxact_id".}
{.pop.}

proc currentSubTransactionId*(): SubTransactionId {.inline.} =
  ## Returns PostgreSQL's current `SubTransactionId` (`GetCurrentSubTransactionId()`).
  pgxCurrentSubXactIdRaw()

template pgxWithLibcAlloc*(body: untyped): untyped =
  ## Forces Nim allocations inside `body` to bypass PostgreSQL's `CurrentMemoryContext`
  ## (`palloc`) and allocate in process-lifetime libc memory via `__real_malloc`.
  pgxPushLibcAlloc()
  try:
    body
  finally:
    pgxPopLibcAlloc()

# =============================================================================
# Process-Lifetime Libc-Backed Callback Registry (Zero Wrapper Closures)
# =============================================================================

type
  XactNode = object
    id: uint64
    active: bool
    hasFilter: bool
    includeParallel: bool
    once: bool
    targetEvent: XactEvent
    parallelEvent: XactEvent
    cb: XactCallbackProc
    simpleCb: XactSimpleProc
    next: ptr XactNode

  SubXactNode = object
    id: uint64
    active: bool
    hasFilter: bool
    once: bool
    targetEvent: SubXactEvent
    cb: SubXactCallbackProc
    simpleCb: SubXactSimpleProc
    zeroCb: XactSimpleProc
    next: ptr SubXactNode

  CallbackList[N] = object
    head: ptr N
    tail: ptr N
    nextId: uint64
    dispatchDepth: int
    needsSweep: bool

var
  xactList: CallbackList[XactNode]
  subXactList: CallbackList[SubXactNode]

proc resetNodeCallbacks(n: var XactNode) {.inline.} =
  reset(n.cb)
  reset(n.simpleCb)

proc resetNodeCallbacks(n: var SubXactNode) {.inline.} =
  reset(n.cb)
  reset(n.simpleCb)
  reset(n.zeroCb)

proc allocNode[N](list: var CallbackList[N]): ptr N =
  if list.nextId == 0'u64:
    list.nextId = 1'u64
  let node = cast[ptr N](real_calloc(1.csize_t, csize_t(sizeof(N))))
  if node == nil:
    raise newException(OutOfMemDefect, "Failed to allocate transaction callback node")
  node.id = list.nextId
  inc list.nextId
  node.active = true
  node.next = nil
  if list.tail == nil:
    list.head = node
    list.tail = node
  else:
    list.tail.next = node
    list.tail = node
  result = node

proc sweepInactive[N](list: var CallbackList[N]) =
  if not list.needsSweep or list.dispatchDepth > 0:
    return
  pgxWithLibcAlloc:
    var prev: ptr N = nil
    var cur = list.head
    while cur != nil:
      let nxt = cur.next
      if not cur.active:
        if prev == nil:
          list.head = nxt
        else:
          prev.next = nxt
        if list.tail == cur:
          list.tail = prev
        resetNodeCallbacks(cur[])
        real_free(cur)
      else:
        prev = cur
      cur = nxt
    list.needsSweep = false

proc removeCallback[N](list: var CallbackList[N], id: uint64): bool =
  if id == 0'u64:
    return false
  var prev: ptr N = nil
  var cur = list.head
  while cur != nil:
    if cur.id == id and cur.active:
      cur.active = false
      if list.dispatchDepth == 0:
        let nxt = cur.next
        if prev == nil:
          list.head = nxt
        else:
          prev.next = nxt
        if list.tail == cur:
          list.tail = prev
        pgxWithLibcAlloc:
          resetNodeCallbacks(cur[])
        real_free(cur)
      else:
        list.needsSweep = true
      return true
    prev = cur
    cur = cur.next
  return false

proc clearCallbacks[N](list: var CallbackList[N]) =
  var cur = list.head
  while cur != nil:
    let nxt = cur.next
    if cur.active:
      cur.active = false
      if list.dispatchDepth > 0:
        list.needsSweep = true
    if list.dispatchDepth == 0:
      pgxWithLibcAlloc:
        resetNodeCallbacks(cur[])
      real_free(cur)
    cur = nxt
  if list.dispatchDepth == 0:
    list.head = nil
    list.tail = nil
    list.needsSweep = false

proc countActive[N](list: CallbackList[N]): int =
  var cur = list.head
  while cur != nil:
    if cur.active:
      inc result
    cur = cur.next

# =============================================================================
# Guarded C-ABI Dispatchers & Anti-PANIC Shield
# =============================================================================

type
  XactInvokeEnv = object
    invokeFn: proc(ctx: pointer) {.nimcall.}
    ctx: pointer
    nimEx: ref CatchableError
    nimDefect: ref Defect

  XactCallArgs = object
    cb: XactCallbackProc
    event: XactEvent

  SimpleCallArgs = object
    cb: XactSimpleProc

  SubXactCallArgs = object
    cb: SubXactCallbackProc
    event: SubXactEvent
    mySubid: SubTransactionId
    parentSubid: SubTransactionId

  SubXactSimpleArgs = object
    cb: SubXactSimpleProc
    mySubid: SubTransactionId
    parentSubid: SubTransactionId

proc xactGuardedRunner(data: pointer) {.cdecl.} =
  let env = cast[ptr XactInvokeEnv](data)
  try:
    env.invokeFn(env.ctx)
  except CatchableError as e:
    env.nimEx = e
  except Defect as e:
    env.nimDefect = e

proc invokeXactCall(ctx: pointer) {.nimcall.} =
  let a = cast[ptr XactCallArgs](ctx)
  a.cb(a.event)

proc invokeSimpleCall(ctx: pointer) {.nimcall.} =
  let a = cast[ptr SimpleCallArgs](ctx)
  a.cb()

proc invokeSubXactCall(ctx: pointer) {.nimcall.} =
  let a = cast[ptr SubXactCallArgs](ctx)
  a.cb(a.event, a.mySubid, a.parentSubid)

proc invokeSubXactSimpleCall(ctx: pointer) {.nimcall.} =
  let a = cast[ptr SubXactSimpleArgs](ctx)
  a.cb(a.mySubid, a.parentSubid)

proc executeGuardedCallback(
  invokeFn: proc(ctx: pointer) {.nimcall.},
  argsPtr: pointer,
  phaseLabel: string,
  isErrorable: bool,
  errPending: var bool,
  errCode: var cint,
  errMsg, errDetail, errHint: var cstring
): bool =
  var env = XactInvokeEnv(invokeFn: invokeFn, ctx: argsPtr, nimEx: nil, nimDefect: nil)
  var captured: PgxCapturedError
  var savedFrame = pgxSaveFrameState()
  let pgOk = pgxCallGuarded(xactGuardedRunner, addr env, addr captured)
  if not pgOk:
    pgxRestoreFrameState(savedFrame)
  reset(savedFrame)

  if pgOk and env.nimEx == nil and env.nimDefect == nil:
    pgxFreeCapturedError(addr captured)
    return true

  if not isErrorable:
    pgxWithLibcAlloc:
      var warnMsg =
        if env.nimDefect != nil:
          "pgxcrown " & phaseLabel & " callback defect [" & $env.nimDefect.name & "]: " & env.nimDefect.msg
        elif env.nimEx != nil:
          "pgxcrown " & phaseLabel & " callback error [" & $env.nimEx.name & "]: " & env.nimEx.msg
        else:
          "pgxcrown " & phaseLabel & " callback PostgreSQL error: " &
            (if captured.message != nil: $captured.message else: "unknown error")
      pgxXactEmitWarningRaw(cstring(warnMsg))
      reset(warnMsg)
    reset(env.nimEx)
    reset(env.nimDefect)
    pgxFreeCapturedError(addr captured)
    return true

  if env.nimDefect != nil:
    prepareNimDefect(env.nimDefect, errCode, errMsg, errDetail, errHint)
    pgxFreeCapturedError(addr captured)
  elif env.nimEx != nil:
    prepareNimError(env.nimEx, errCode, errMsg, errDetail, errHint)
    pgxFreeCapturedError(addr captured)
  else:
    errCode = captured.sqlerrcode
    errMsg = captured.message
    errDetail = captured.detail
    errHint = captured.hint
    if captured.context != nil:
      pfree(cast[pointer](captured.context))
  reset(env.nimEx)
  reset(env.nimDefect)
  errPending = true
  return false

proc pgxXactDispatch(rawEvent: cint, arg: pointer) {.cdecl.} =
  if rawEvent < ord(low(XactEvent)).cint or rawEvent > ord(high(XactEvent)).cint:
    return
  if xactList.head == nil:
    return

  let event = XactEvent(rawEvent)
  let isErrorable = isErrorableXactEvent(event)
  var errPending = false
  var errCode: cint = 0
  var errMsg: cstring = nil
  var errDetail: cstring = nil
  var errHint: cstring = nil

  inc xactList.dispatchDepth
  try:
    let stopAfter = xactList.tail
    var cur = xactList.head
    while cur != nil:
      let isLast = (cur == stopAfter)
      if cur.active:
        var keepGoing = true
        if cur.hasFilter:
          let matched = (event == cur.targetEvent) or
                        (cur.includeParallel and event == cur.parallelEvent)
          if matched:
            var callArgs = SimpleCallArgs(cb: cur.simpleCb)
            if cur.once:
              cur.active = false
              xactList.needsSweep = true
            keepGoing = executeGuardedCallback(
              invokeSimpleCall, addr callArgs, $event, isErrorable,
              errPending, errCode, errMsg, errDetail, errHint
            )
            reset(callArgs.cb)
          elif cur.once and event in {xeAbort, xeParallelAbort, xeCommit, xeParallelCommit}:
            cur.active = false
            xactList.needsSweep = true
        else:
          var callArgs = XactCallArgs(cb: cur.cb, event: event)
          keepGoing = executeGuardedCallback(
            invokeXactCall, addr callArgs, $event, isErrorable,
            errPending, errCode, errMsg, errDetail, errHint
          )
          reset(callArgs.cb)
        if not keepGoing:
          break
      if isLast:
        break
      cur = cur.next
  finally:
    dec xactList.dispatchDepth
    sweepInactive(xactList)

  if errPending:
    pgxEreportFull(ERROR, errCode, errMsg, errDetail, errHint)
    if errMsg != nil: pfree(cast[pointer](errMsg))
    if errDetail != nil: pfree(cast[pointer](errDetail))
    if errHint != nil: pfree(cast[pointer](errHint))

proc pgxSubXactDispatch(rawEvent: cint, mySubid: cuint, parentSubid: cuint,
                        arg: pointer) {.cdecl.} =
  if rawEvent < ord(low(SubXactEvent)).cint or rawEvent > ord(high(SubXactEvent)).cint:
    return
  if subXactList.head == nil:
    return

  let event = SubXactEvent(rawEvent)
  let isErrorable = isErrorableSubXactEvent(event)
  let myId = SubTransactionId(mySubid)
  let parentId = SubTransactionId(parentSubid)
  var errPending = false
  var errCode: cint = 0
  var errMsg: cstring = nil
  var errDetail: cstring = nil
  var errHint: cstring = nil

  inc subXactList.dispatchDepth
  try:
    let stopAfter = subXactList.tail
    var cur = subXactList.head
    while cur != nil:
      let isLast = (cur == stopAfter)
      if cur.active:
        var keepGoing = true
        if cur.hasFilter:
          if event == cur.targetEvent:
            if cur.simpleCb != nil:
              var callArgs = SubXactSimpleArgs(
                cb: cur.simpleCb, mySubid: myId, parentSubid: parentId
              )
              if cur.once:
                cur.active = false
                subXactList.needsSweep = true
              keepGoing = executeGuardedCallback(
                invokeSubXactSimpleCall, addr callArgs, $event, isErrorable,
                errPending, errCode, errMsg, errDetail, errHint
              )
              reset(callArgs.cb)
            elif cur.zeroCb != nil:
              var callArgs = SimpleCallArgs(cb: cur.zeroCb)
              if cur.once:
                cur.active = false
                subXactList.needsSweep = true
              keepGoing = executeGuardedCallback(
                invokeSimpleCall, addr callArgs, $event, isErrorable,
                errPending, errCode, errMsg, errDetail, errHint
              )
              reset(callArgs.cb)
        else:
          var callArgs = SubXactCallArgs(
            cb: cur.cb, event: event, mySubid: myId, parentSubid: parentId
          )
          keepGoing = executeGuardedCallback(
            invokeSubXactCall, addr callArgs, $event, isErrorable,
            errPending, errCode, errMsg, errDetail, errHint
          )
          reset(callArgs.cb)
        if not keepGoing:
          break
      if isLast:
        break
      cur = cur.next
  finally:
    dec subXactList.dispatchDepth
    sweepInactive(subXactList)

  if errPending:
    pgxEreportFull(ERROR, errCode, errMsg, errDetail, errHint)
    if errMsg != nil: pfree(cast[pointer](errMsg))
    if errDetail != nil: pfree(cast[pointer](errDetail))
    if errHint != nil: pfree(cast[pointer](errHint))

proc ensureXactRegistered() =
  pgxSetXactDispatcherRaw(pgxXactDispatch)
  pgxEnsureXactRegisteredRaw()

proc ensureSubXactRegistered() =
  pgxSetSubXactDispatcherRaw(pgxSubXactDispatch)
  pgxEnsureSubXactRegisteredRaw()

# =============================================================================
# Public Registration & Convenience API
# =============================================================================

proc registerXactCallback*(cb: XactCallbackProc): XactHandle =
  ## Registers a PostgreSQL transaction lifecycle callback (`XactEvent`).
  ## Idempotently installs the underlying C singleton dispatcher via
  ## `RegisterXactCallback`. Returns an `XactHandle` that can be passed to
  ## `unregisterXactCallback`.
  if cb == nil:
    raise newException(ValueError, "registerXactCallback callback must not be nil")
  ensureXactRegistered()
  let node = allocNode(xactList)
  node.hasFilter = false
  node.cb = cb
  result = XactHandle(node.id)

proc unregisterXactCallback*(handle: XactHandle): bool {.discardable.} =
  ## Unregisters a previously registered transaction callback.
  ## Safe to call from inside an active callback (deferred cleanup occurs after
  ## callback dispatch finishes) and idempotent on stale/already-removed handles.
  removeCallback(xactList, uint64(handle))

proc registerSubXactCallback*(cb: SubXactCallbackProc): SubXactHandle =
  ## Registers a PostgreSQL subtransaction lifecycle callback (`SubXactEvent`).
  ## Idempotently installs the underlying C singleton dispatcher via
  ## `RegisterSubXactCallback`. Returns a `SubXactHandle` for
  ## `unregisterSubXactCallback`.
  if cb == nil:
    raise newException(ValueError, "registerSubXactCallback callback must not be nil")
  ensureSubXactRegistered()
  let node = allocNode(subXactList)
  node.hasFilter = false
  node.cb = cb
  result = SubXactHandle(node.id)

proc unregisterSubXactCallback*(handle: SubXactHandle): bool {.discardable.} =
  ## Unregisters a previously registered subtransaction callback.
  ## Safe to call during callback iteration and idempotent on stale handles.
  removeCallback(subXactList, uint64(handle))

proc xactCallbackCount*(): int {.inline.} =
  ## Returns the number of currently active registered `XactEvent` callbacks.
  countActive(xactList)

proc subXactCallbackCount*(): int {.inline.} =
  ## Returns the number of currently active registered `SubXactEvent` callbacks.
  countActive(subXactList)

proc clearXactCallbacks*() =
  ## Unregisters all currently active transaction and subtransaction callbacks.
  clearCallbacks(xactList)
  clearCallbacks(subXactList)

proc registerFilteredXact(
  target: XactEvent,
  parallelTarget: XactEvent,
  includeParallel: bool,
  once: bool,
  cb: XactSimpleProc,
  procName: string
): XactHandle =
  if cb == nil:
    raise newException(ValueError, procName & " callback must not be nil")
  ensureXactRegistered()
  let node = allocNode(xactList)
  node.hasFilter = true
  node.includeParallel = includeParallel
  node.once = once
  node.targetEvent = target
  node.parallelEvent = parallelTarget
  node.simpleCb = cb
  result = XactHandle(node.id)

proc onCommit*(cb: XactSimpleProc, includeParallel: bool = false,
               once: bool = false): XactHandle {.discardable.} =
  ## Convenience helper registering a callback invoked on `xeCommit`
  ## (and `xeParallelCommit` when `includeParallel` is true).
  ## When `once` is true, the callback auto-unregisters after firing or if the
  ## transaction ends via abort.
  registerFilteredXact(xeCommit, xeParallelCommit, includeParallel, once, cb, "onCommit")

proc onAbort*(cb: XactSimpleProc, includeParallel: bool = false,
              once: bool = false): XactHandle {.discardable.} =
  ## Convenience helper registering a callback invoked on `xeAbort`
  ## (and `xeParallelAbort` when `includeParallel` is true).
  ## When `once` is true, the callback auto-unregisters after firing or if the
  ## transaction ends via commit.
  registerFilteredXact(xeAbort, xeParallelAbort, includeParallel, once, cb, "onAbort")

proc onPreCommit*(cb: XactSimpleProc, includeParallel: bool = false,
                  once: bool = false): XactHandle {.discardable.} =
  ## Convenience helper registering a callback invoked on `xePreCommit`
  ## (and `xeParallelPreCommit` when `includeParallel` is true).
  ## Raising an exception inside this callback cleanly aborts the transaction
  ## with a controlled PostgreSQL `ERROR`.
  registerFilteredXact(xePreCommit, xeParallelPreCommit, includeParallel, once, cb, "onPreCommit")

proc registerFilteredSubXact(
  target: SubXactEvent,
  once: bool,
  simpleCb: SubXactSimpleProc,
  zeroCb: XactSimpleProc,
  procName: string
): SubXactHandle =
  if simpleCb == nil and zeroCb == nil:
    raise newException(ValueError, procName & " callback must not be nil")
  ensureSubXactRegistered()
  let node = allocNode(subXactList)
  node.hasFilter = true
  node.once = once
  node.targetEvent = target
  node.simpleCb = simpleCb
  node.zeroCb = zeroCb
  result = SubXactHandle(node.id)

proc onSubXactCommit*(cb: SubXactSimpleProc, once: bool = false): SubXactHandle {.discardable.} =
  ## Convenience helper registering a callback invoked on `sxeCommitSub`,
  ## receiving `(mySubid, parentSubid)`.
  registerFilteredSubXact(sxeCommitSub, once, cb, nil, "onSubXactCommit")

proc onSubXactCommit*(cb: XactSimpleProc, once: bool = false): SubXactHandle {.discardable.} =
  ## Zero-argument convenience overload of `onSubXactCommit`.
  registerFilteredSubXact(sxeCommitSub, once, nil, cb, "onSubXactCommit")

proc onSubXactAbort*(cb: SubXactSimpleProc, once: bool = false): SubXactHandle {.discardable.} =
  ## Convenience helper registering a callback invoked on `sxeAbortSub`,
  ## receiving `(mySubid, parentSubid)`.
  registerFilteredSubXact(sxeAbortSub, once, cb, nil, "onSubXactAbort")

proc onSubXactAbort*(cb: XactSimpleProc, once: bool = false): SubXactHandle {.discardable.} =
  ## Zero-argument convenience overload of `onSubXactAbort`.
  registerFilteredSubXact(sxeAbortSub, once, nil, cb, "onSubXactAbort")
