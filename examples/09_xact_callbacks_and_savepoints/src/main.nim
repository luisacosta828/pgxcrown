import pgxcrown
import std/strutils

var
  gAuditLog {.global.}: seq[string] = @[]
  gCommitCount {.global.}: int64 = 0
  gAbortCount {.global.}: int64 = 0
  gSubXactHandle {.global.}: SubXactHandle = InvalidSubXactHandle

proc appendAudit(msg: string) =
  ## Allocates log strings on libc heap so they survive PostgreSQL MemoryContext resets.
  pgxWithLibcAlloc:
    var copyStr = newString(msg.len)
    if msg.len > 0:
      copyMem(addr copyStr[0], unsafeAddr msg[0], msg.len)
    gAuditLog.add(copyStr)

proc armTxLibc(tag: string): int32 {.noSql.} =
  var tagCopy = newString(tag.len)
  if tag.len > 0:
    copyMem(addr tagCopy[0], unsafeAddr tag[0], tag.len)

  discard onPreCommit((proc() =
    appendAudit("pre:" & tagCopy)
  ), once = true)
  discard onCommit((proc() =
    inc gCommitCount
    appendAudit("commit:" & tagCopy)
  ), once = true)
  discard onAbort((proc() =
    inc gAbortCount
    appendAudit("abort:" & tagCopy)
  ), once = true)
  int32(xactCallbackCount())

proc ex09_reset*(): string {.volatile.} =
  clearXactCallbacks()
  gSubXactHandle = InvalidSubXactHandle
  gCommitCount = 0
  gAbortCount = 0
  pgxWithLibcAlloc:
    gAuditLog.setLen(0)
  "xact=" & $xactCallbackCount() & "|subxact=" & $subXactCallbackCount()

proc ex09_arm_tx*(tag: string): int32 {.volatile.} =
  ## Arms one-shot pre-commit, commit, and abort callbacks with libc-allocated closure state.
  var cnt: int32 = 0
  pgxWithLibcAlloc:
    cnt = armTxLibc(tag)
  cnt

proc ex09_arm_subxact*(): int32 {.volatile.} =
  ## Tracks SAVEPOINT / ROLLBACK TO SAVEPOINT / RELEASE SAVEPOINT lifecycle events.
  if gSubXactHandle.isValid:
    discard unregisterSubXactCallback(gSubXactHandle)
    gSubXactHandle = InvalidSubXactHandle
  pgxWithLibcAlloc:
    gSubXactHandle = registerSubXactCallback(proc(ev: SubXactEvent, mySubid, parentSubid: SubTransactionId) =
      if ev in {sxeCommitSub, sxeAbortSub}:
        appendAudit($ev & ":" & $(mySubid > parentSubid))
    )
  int32(subXactCallbackCount())

proc ex09_arm_abort_shield*(): int32 {.volatile.} =
  ## Demonstrates Anti-PANIC Shield: an exception in xeAbort becomes a WARNING, not a server PANIC.
  pgxWithLibcAlloc:
    discard onAbort((proc() =
      appendAudit("shield_before")
      raise newException(ValueError, "simulated cleanup error")
    ), once = true)
    discard onAbort((proc() =
      appendAudit("shield_tail_ok")
    ), once = true)
  int32(xactCallbackCount())

proc ex09_arm_precommit_policy*(): int32 {.volatile.} =
  ## Demonstrates controlled abort from xePreCommit while xeAbort handlers still run cleanly.
  pgxWithLibcAlloc:
    discard onPreCommit((proc() =
      appendAudit("precommit_check")
      raisePgError("P0001", "blocked by ex09 precommit policy")
    ), once = true)
    discard onAbort((proc() =
      appendAudit("policy_aborted")
    ), once = true)
  int32(xactCallbackCount())

proc ex09_take_log*(disarmSubxact: bool = false): string {.volatile.} =
  result = gAuditLog.join(" | ")
  if result.len == 0:
    result = "<empty>"
  pgxWithLibcAlloc:
    gAuditLog.setLen(0)
  if disarmSubxact and gSubXactHandle.isValid:
    discard unregisterSubXactCallback(gSubXactHandle)
    gSubXactHandle = InvalidSubXactHandle

proc ex09_stats*(): string {.volatile.} =
  "committed=" & $gCommitCount & "|aborted=" & $gAbortCount &
    "|xact_cbs=" & $xactCallbackCount() & "|subxact_cbs=" & $subXactCallbackCount()
