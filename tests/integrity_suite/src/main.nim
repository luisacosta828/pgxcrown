import pgxcrown
import std/[algorithm, strutils]

proc att_echo*(x: int32): int32 {.immutable, parallelSafe.} =
  x * 2'i32

proc att_echo*(x: string): string {.immutable, parallelSafe.} =
  "echo:" & x

proc att_sec_fn*(x: int32): int32 {.stable, securityDefiner, searchPath: "public, pg_catalog".} =
  x + 100'i32

var attProcAcc {.global.}: int32 = 0

proc att_ping_proc*(delta: int32) {.volatile.} =
  attProcAcc += delta

proc att_proc_total*(): int32 {.volatile.} =
  attProcAcc

proc att_compiled_count*(): int32 {.immutable.} =
  int32(PgxCompiledFunctions.len)

proc att_loaded_so_info*(): string {.volatile.} =
  let soPath = findLoadedSoPath(PgxExtensionName)
  let sha1 = loadedSoSha256(PgxExtensionName)
  let sha2 = loadedSoSha256(PgxExtensionName)
  let missingPath = findLoadedSoPath("nonexistent_pgx_ext_xyz")
  var allLowerHex = (sha1.len == 64)
  for ch in sha1:
    if ch notin {'0'..'9', 'a'..'f'}:
      allLowerHex = false
  "path_ok=" & $soPath.endsWith("/" & PgxExtensionName & ".so") &
    "|len64=" & $(sha1.len == 64) &
    "|hex=" & $allLowerHex &
    "|deterministic=" & $(sha1 == sha2) &
    "|missing_empty=" & $(missingPath.len == 0)

proc att_is_intact*(): bool {.stable.} =
  isCatalogIntact(PgxExtensionName, PgxCompiledFunctions)

proc att_check_catalog*(): string {.stable.} =
  let violations = verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)
  if violations.len == 0:
    return "OK"
  var items: seq[string] = @[]
  for v in violations:
    items.add(v.code & ":" & v.functionName)
  items.sort()
  items.join(",")

proc att_assert_intact*(): string {.stable.} =
  assertCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  "INTACT"
