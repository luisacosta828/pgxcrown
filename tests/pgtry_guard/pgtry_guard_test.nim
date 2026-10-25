import pgxcrown

# -----------------------------------------------------------------------------
# 🛡️ PG_TRY Guard Regression Suite
# Every fetchRawRows() / SPI call goes through pgTry -> pgx_call_guarded
# (reports/reports.nim). Returning from inside the C PG_TRY block used to leave
# PG_exception_stack dangling, so any error raised later in the SAME UDF call
# segfaulted the backend. These UDFs exercise that exact pattern.
# -----------------------------------------------------------------------------

# Baseline: error without any prior SPI call
proc plain_raise*(): int32 {.volatile.} =
  raisePgError(ERRCODE_INVALID_PARAMETER_VALUE, "baseline: no SPI before")
  return 0

# Successful pgTry, then a PgError
proc ok_then_raise*(): int32 {.volatile.} =
  let rows = fetchRawRows("SELECT 1 AS x")
  if rows.len > 0:
    raisePgError(ERRCODE_INVALID_PARAMETER_VALUE, "boom after successful pgTry")
  return 0

# Successful pgTry, then a Nim Defect (IndexDefect) handled by the Panic Shield
proc ok_then_defect*(idx: int32): int32 {.volatile.} =
  let rows = fetchRawRows("SELECT 1 AS x")
  let items = [10'i32, 20, 30]
  return items[idx + int32(rows.len)]

# Successful pgTry, normal return
proc ok_return*(): int32 {.volatile.} =
  let rows = fetchRawRows("SELECT 1 AS x")
  return int32(rows.len)
