import pgxcrown/pgx
import std/os

## =============================================================================
## 💥 Memory Chaos Test Extension for Pgxcrown
## Verifies that memory allocated by Nim inside PostgreSQL is 100% reclaimed
## when a query is cancelled via pg_cancel_backend() or statement_timeout.
## =============================================================================

proc get_current_pid*(): int32 =
  ## Returns the process ID of the PostgreSQL backend handling this session.
  return os.getCurrentProcessId().int32

proc allocate_and_sleep*(megabytes: int32, sleep_seconds: int32): int32 =
  ## Allocates `megabytes` of heap memory in Nim (strings of 1KB each)
  ## and then sleeps for `sleep_seconds`.
  ## This allows testing `pg_cancel_backend(pid)` while memory is held.
  let numStrings = megabytes * 1024 # 1 string per KB
  var chunks = newSeq[string](numStrings)

  # Fill each string with 1000 characters to ensure real physical memory pages are touched (RSS inflation)
  let dummyPayload = repeat("X", 1000)
  for i in 0 ..< numStrings:
    chunks[i] = dummyPayload

  # Sleep to give the tester time to cancel the query from another terminal
  os.sleep(sleep_seconds * 1000)

  return chunks.len.int32

proc allocate_and_fail*(megabytes: int32): int32 =
  ## Allocates `megabytes` in Nim, then deliberately triggers an immediate
  ## exception to verify that repeated aborts do NOT cause memory leaks.
  let numStrings = megabytes * 1024
  var chunks = newSeq[string](numStrings)
  let dummyPayload = repeat("Y", 1000)
  for i in 0 ..< numStrings:
    chunks[i] = dummyPayload

  # Trigger error (IndexDefect -> Panic Shield -> ereport ERROR)
  let invalidIdx = numStrings + 100
  chunks[invalidIdx] = "Trigger failure"

  return chunks.len.int32
