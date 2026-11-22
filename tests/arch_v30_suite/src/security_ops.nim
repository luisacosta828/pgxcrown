import pgxcrown
import std/strutils

proc v30_privileged_vault_count*(): int64 {.securityDefiner, searchPath: "public, pg_catalog".} =
  let rows = fetchRawRows("SELECT count(*)::bigint AS cnt FROM arch_v30_priv_vault")
  if rows.len == 0 or not rows[0].hasKey("cnt"):
    return 0
  result = parseBiggestInt(rows[0]["cnt"])

proc v30_caller_vault_count*(): int64 {.securityInvoker, searchPath: "public, pg_catalog".} =
  let rows = fetchRawRows("SELECT count(*)::bigint AS cnt FROM arch_v30_priv_vault")
  if rows.len == 0 or not rows[0].hasKey("cnt"):
    return 0
  result = parseBiggestInt(rows[0]["cnt"])

proc v30_safe_is_even*(x: int32): bool {.immutable, parallelSafe, leakproof.} =
  (x mod 2'i32) == 0'i32
