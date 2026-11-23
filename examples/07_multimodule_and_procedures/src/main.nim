import pgxcrown
import ./billing_ops

pgxExtension:
  version = "0.1.0"
  comment = "Multi-module pgxcrown extension with SQL PROCEDURE, SECURITY DEFINER, and LEAKPROOF"
  relocatable = true
  trusted = true

var mainInitBias: int32 = 0

proc initMainModule() {.pgxInit.} =
  mainInitBias = 7'i32

proc ex07_init_status*(): int32 {.volatile.} =
  ## Verifies deterministic {.pgxInit.} execution across `billing_ops.nim` and `main.nim`.
  billingInitBias + mainInitBias

proc ex07_reset_ledger*() {.volatile.} =
  ## SQL PROCEDURE (`CALL ex07_reset_ledger()`) with zero return value.
  billingLedgerCents = 0'i64
