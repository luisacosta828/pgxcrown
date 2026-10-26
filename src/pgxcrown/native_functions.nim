## =============================================================================
## PostgreSQL Native Functions Module for pgxcrown
## Provides type-safe SQL expression constructors for PostgreSQL built-in functions.
## =============================================================================

import query_builder

proc sqlNow*(): SqlExpr {.inline.} =
  ## Native PostgreSQL `now()` timestamp function
  SqlExpr(sql: "now()")

proc sqlClockTimestamp*(): SqlExpr {.inline.} =
  ## Native PostgreSQL `clock_timestamp()` current wall-clock timestamp function
  SqlExpr(sql: "clock_timestamp()")

proc sqlCurrentDate*(): SqlExpr {.inline.} =
  ## Native PostgreSQL `CURRENT_DATE` function
  SqlExpr(sql: "CURRENT_DATE")

proc sqlCurrentTimestamp*(): SqlExpr {.inline.} =
  ## Native PostgreSQL `CURRENT_TIMESTAMP` function
  SqlExpr(sql: "CURRENT_TIMESTAMP")

proc sqlRandom*(): SqlExpr {.inline.} =
  ## Native PostgreSQL `random()` float generator function
  SqlExpr(sql: "random()")
