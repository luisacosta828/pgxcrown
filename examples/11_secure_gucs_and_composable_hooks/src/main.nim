import pgxcrown
import std/[algorithm, strutils]

var
  gMaxRowsGuc: GucVar[int32]
  gStrictGuardGuc: GucVar[bool]
  gAuditTokenGuc: GucVar[string]

  gExecEndQueries {.global.}: int64 = 0
  gExecEndRows {.global.}: uint64 = 0
  gBlockedDrops {.global.}: int64 = 0
  gAllowedDrops {.global.}: int64 = 0

proc isInternalHookCtrlQuery(sqlText: string): bool {.inline.} =
  "ex11_hook_" in sqlText or "ex11_reset_hooks" in sqlText

proc onEx11ExecutorEnd(info: ExecutorQueryInfo) =
  let sqlText = info.sourceText
  if isInternalHookCtrlQuery(sqlText):
    return
  if "ex11_tracked_tbl" notin sqlText:
    return
  inc gExecEndQueries
  gExecEndRows += info.rowsProcessed

proc onEx11ProcessUtility(info: UtilityStmtInfo) =
  if info.isDropTable:
    if info.dropTargetsContain("ex11_protected_tbl"):
      inc gBlockedDrops
      raisePgError(
        "42501",
        "DROP TABLE ex11_protected_tbl blocked by ex11 policy",
        detail = "Targets: " & info.dropTargetsCsv,
        hint = "ex11_protected_tbl cannot be dropped while policy hook is active"
      )
    elif info.dropTargetsContain("ex11_scratch_tbl"):
      inc gAllowedDrops

proc ex11_init*() {.pgxInit.} =
  gMaxRowsGuc = defineGucInt(
    "ex11.max_rows",
    "Maximum rows per audited batch",
    "User-configurable bounded row limit",
    bootValue = 50,
    minVal = 1,
    maxVal = 1000,
    context = gcUserset
  )
  gStrictGuardGuc = defineGucBool(
    "ex11.strict_guard",
    "Strict DDL/policy enforcement",
    "Superuser-only strict policy toggle",
    bootValue = true,
    context = gcSuset
  )
  gAuditTokenGuc = defineGucString(
    "ex11.audit_token",
    "Superuser-only audit signing token",
    "Protected GUC hidden from non-superusers via GUC_SUPERUSER_ONLY",
    bootValue = "ex11-secret-boot",
    context = gcSuset,
    superuserOnly = true
  )
  reserveGucPrefix("ex11")
  registerExecutorEndHook(onEx11ExecutorEnd, hpPre)
  registerProcessUtilityHook(onEx11ProcessUtility, hpPre)

proc ex11_guc_status*(): string {.volatile.} =
  "max_rows=" & $gMaxRowsGuc.get() & "|strict_guard=" & $gStrictGuardGuc.get()

proc ex11_read_audit_token*(): string {.volatile.} =
  ## Gates access through getGuc so non-superusers always hit SQLSTATE 42501.
  discard getGuc("ex11.audit_token")
  gAuditTokenGuc.get()

proc ex11_set_max_rows_local*(val: string): string {.volatile.} =
  setGuc("ex11.max_rows", val, isLocal = true, allowedPrefix = "ex11")
  "ok"

proc ex11_reset_hooks*(): string {.volatile.} =
  gExecEndQueries = 0
  gExecEndRows = 0
  gBlockedDrops = 0
  gAllowedDrops = 0
  "hooks_reset_ok"

proc ex11_hook_stats*(): string {.volatile.} =
  "exec_end=" & $isExecutorEndHookInstalled() &
    "|util=" & $isProcessUtilityHookInstalled() &
    "|queries=" & $gExecEndQueries &
    "|rows=" & $gExecEndRows &
    "|blocked_drops=" & $gBlockedDrops &
    "|allowed_drops=" & $gAllowedDrops

proc ex11_integrity_report*(): string {.stable.} =
  ## Live catalog integrity attestation + loaded ELF .so SHA-256 verification.
  let intact = isCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  let violations = verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)
  let sha = loadedSoSha256(PgxExtensionName)
  var allHex64 = (sha.len == 64)
  for ch in sha:
    if ch notin {'0'..'9', 'a'..'f'}:
      allHex64 = false
  var vCodes: seq[string] = @[]
  for v in violations:
    vCodes.add(v.code & ":" & v.functionName)
  vCodes.sort()
  let vStr = if vCodes.len == 0: "NONE" else: vCodes.join(",")
  "intact=" & $intact &
    "|violations=" & $violations.len &
    "|codes=" & vStr &
    "|sha64=" & $allHex64 &
    "|fns_gt0=" & $(PgxCompiledFunctions.len > 0)

proc ex11_assert_intact*(): string {.stable.} =
  assertCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  "INTACT"
