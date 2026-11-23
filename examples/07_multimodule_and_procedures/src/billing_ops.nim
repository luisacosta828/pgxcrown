import pgxcrown
import std/strutils

var
  billingInitBias*: int32 = 0
  billingLedgerCents* {.global.}: int64 = 0

proc initBillingOps*() {.pgxInit.} =
  ## Runs automatically inside `_PG_init` before `main.nim`'s `{.pgxInit.}`.
  billingInitBias = 100'i32

proc computeCentsInternal*(units, unitPriceCents: int64): int64 {.noSql.} =
  ## Marked {.noSql.} so internal helpers never leak into PostgreSQL `pg_proc`.
  units * unitPriceCents

proc ex07_is_valid_amount*(cents: int64): bool {.immutable, parallelSafe, leakproof.} =
  ## LEAKPROOF pure predicate safe for security-barrier views and RLS pushdown.
  cents > 0'i64

proc ex07_calc_invoice*(units, unitPriceCents: int64): int64 {.immutable, parallelSafe.} =
  computeCentsInternal(units, unitPriceCents)

proc ex07_post_charge*(deltaCents: int64) {.volatile, securityDefiner, searchPath: "public, pg_catalog".} =
  ## Exposed as a SQL PROCEDURE (`CALL ex07_post_charge(...)`) with pinned search_path.
  billingLedgerCents += deltaCents

proc ex07_ledger_total*(): int64 {.volatile.} =
  billingLedgerCents

proc ex07_vault_total*(): int64 {.stable, securityDefiner, searchPath: "public, pg_catalog".} =
  ## Executes with owner privileges and hardened search_path.
  let rows = fetchRawRows("SELECT coalesce(sum(amount_cents), 0)::bigint AS total FROM public.ex07_billing_vault")
  if rows.len == 0 or not rows[0].hasKey("total"):
    return 0'i64
  parseBiggestInt(rows[0]["total"])

proc ex07_caller_vault_total*(): int64 {.stable, securityInvoker, searchPath: "public, pg_catalog".} =
  ## Executes with caller privileges (fails with SQLSTATE 42501 without table GRANT).
  let rows = fetchRawRows("SELECT coalesce(sum(amount_cents), 0)::bigint AS total FROM public.ex07_billing_vault")
  if rows.len == 0 or not rows[0].hasKey("total"):
    return 0'i64
  parseBiggestInt(rows[0]["total"])
