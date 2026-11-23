import std/strutils
import pgxcrown

pgxExtension:
  version = "0.1.0"
  comment = "PostgreSQL Xact & SubXact callbacks verification suite"
  relocatable = true
  trusted = false

var
  gEventLog: seq[string] = @[]
  gSavedHandle: XactHandle = InvalidXactHandle

proc recordEvent(msg: string) =
  pgxWithLibcAlloc:
    var copyStr = newString(msg.len)
    if msg.len > 0:
      copyMem(addr copyStr[0], unsafeAddr msg[0], msg.len)
    gEventLog.add(copyStr)

proc xact_reset_all*(): string {.volatile.} =
  clearXactCallbacks()
  gSavedHandle = InvalidXactHandle
  pgxWithLibcAlloc:
    gEventLog.setLen(0)
  return "xact=" & $xactCallbackCount() & "|subxact=" & $subXactCallbackCount()

proc xact_counts*(): string {.volatile.} =
  return "xact=" & $xactCallbackCount() & "|subxact=" & $subXactCallbackCount()

proc xact_take_log*(disarm: bool = false): string {.volatile.} =
  result = gEventLog.join(" | ")
  if result.len == 0:
    result = "<empty>"
  pgxWithLibcAlloc:
    gEventLog.setLen(0)
  if disarm:
    clearXactCallbacks()
    gSavedHandle = InvalidXactHandle

proc xact_arm_basic*(): int32 {.volatile.} =
  discard registerXactCallback(proc(ev: XactEvent) =
    if ev in {xePreCommit, xeCommit, xeAbort}:
      recordEvent("raw:" & $ev)
  )
  discard onCommit(proc() =
    recordEvent("onCommit")
  )
  discard onAbort(proc() =
    recordEvent("onAbort")
  )
  return int32(xactCallbackCount())

proc xact_arm_subxact*(): int32 {.volatile.} =
  discard registerSubXactCallback(proc(ev: SubXactEvent, mySubid, parentSubid: SubTransactionId) =
    recordEvent("raw:" & $ev & "(" & $mySubid & "<-" & $parentSubid & ")")
  )
  discard onSubXactCommit(proc(mySubid, parentSubid: SubTransactionId) =
    recordEvent("onSubXactCommit(" & $mySubid & "<-" & $parentSubid & ")")
  )
  discard onSubXactAbort(proc(mySubid, parentSubid: SubTransactionId) =
    recordEvent("onSubXactAbort(" & $mySubid & "<-" & $parentSubid & ")")
  )
  return int32(subXactCallbackCount())

proc xact_arm_panic_shield*(mode: string): int32 {.volatile.} =
  let m = $mode
  if m == "abort_exc":
    discard onAbort(proc() =
      recordEvent("abort_throw_before")
      raise newException(ValueError, "nim error in abort")
    )
    discard onAbort(proc() =
      recordEvent("abort_tail_ran")
    )
  elif m == "commit_defect":
    discard onCommit(proc() =
      recordEvent("commit_defect_before")
      let arr = @[10'i32, 20'i32]
      recordEvent("unreachable:" & $arr[5])
    )
    discard onCommit(proc() =
      recordEvent("commit_tail_ran")
    )
  elif m == "abort_pgerror":
    discard onAbort(proc() =
      recordEvent("abort_pgerror_before")
      pgError("22023", "direct pgError in abort")
    )
    discard onAbort(proc() =
      recordEvent("abort_pgerror_tail_ran")
    )
  elif m == "subxact_exc":
    discard onSubXactAbort(proc() =
      recordEvent("sub_abort_throw_before")
      raise newException(ValueError, "nim error in subxact abort")
    )
    discard onSubXactAbort(proc() =
      recordEvent("sub_abort_tail_ran")
    )
    discard onSubXactCommit(proc() =
      recordEvent("sub_commit_throw_before")
      pgError("22023", "direct pgError in subxact commit")
    )
    discard onSubXactCommit(proc() =
      recordEvent("sub_commit_tail_ran")
    )
  return int32(xactCallbackCount() + subXactCallbackCount())

proc xact_arm_precommit_fail*(mode: string): int32 {.volatile.} =
  let m = $mode
  if m == "pgerror":
    discard onPreCommit(proc() =
      recordEvent("precommit_about_to_fail")
      raisePgError("P0001", "blocked by pre-commit policy",
                   detail = "policy=strict", hint = "fix transaction")
    )
    discard onAbort(proc() =
      recordEvent("abort_after_precommit_fail")
    )
  elif m == "defect":
    discard registerXactCallback(proc(ev: XactEvent) =
      if ev == xePreCommit:
        let items = @[1'i32]
        recordEvent("bad:" & $items[9])
    )
    discard onAbort(proc() =
      recordEvent("abort_after_defect")
    )
  elif m == "sub":
    discard registerSubXactCallback(proc(ev: SubXactEvent, mySubid, parentSubid: SubTransactionId) =
      if ev == sxePreCommitSub:
        recordEvent("sub_precommit_fail")
        raisePgError("22023", "blocked subxact pre-commit")
    )
    discard onSubXactAbort(proc() =
      recordEvent("sub_abort_after_precommit_fail")
    )
  return int32(xactCallbackCount() + subXactCallbackCount())

proc armLifecycleInLibc(tagStr: string): string {.noSql.} =
  gEventLog.setLen(0)
  let capturedTag = "cap:" & tagStr
  gSavedHandle = onCommit(proc() =
    recordEvent(capturedTag)
  )
  let deadHandle = onCommit(proc() =
    recordEvent("should_never_fire")
  )
  let u1 = unregisterXactCallback(deadHandle)
  let u2 = unregisterXactCallback(deadHandle)

  let onceTag = "once:" & tagStr
  discard onCommit((proc() = recordEvent(onceTag)), once = true)

  var selfHandle = InvalidXactHandle
  selfHandle = registerXactCallback(proc(ev: XactEvent) =
    if ev == xePreCommit:
      recordEvent("self_precommit_unreg")
      discard unregisterXactCallback(selfHandle)
    elif ev == xeCommit:
      recordEvent("self_should_not_reach_commit")
  )

  return "saved=" & $gSavedHandle.isValid & "|u1=" & $u1 & "|u2=" & $u2 & "|cnt=" & $xactCallbackCount()

proc xact_setup_lifecycle_test*(tag: string): string {.volatile.} =
  clearXactCallbacks()
  var res = ""
  pgxWithLibcAlloc:
    res = armLifecycleInLibc($tag)
  return res

proc xact_unregister_saved*(): string {.volatile.} =
  let first = unregisterXactCallback(gSavedHandle)
  let second = unregisterXactCallback(gSavedHandle)
  gSavedHandle = InvalidXactHandle
  return "first=" & $first & "|second=" & $second & "|cnt=" & $xactCallbackCount()
