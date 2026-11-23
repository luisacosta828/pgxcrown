import pgxcrown
import std/options

type
  GucSecMode {.noSql.} = enum
    gsmFast = "fast"
    gsmSafe = "safe"

var
  maxItemsGuc: GucVar[int32]
  adminFlagGuc: GucVar[bool]
  secretKeyGuc: GucVar[string]
  modeGuc: GucVar[GucSecMode]

proc guc_security_init*() {.pgxInit.} =
  maxItemsGuc = defineGucInt(
    "gucsec.max_items",
    "Maximum items allowed",
    "Bounded integer parameter configurable by regular users",
    bootValue = 10,
    minVal = 1,
    maxVal = 1000,
    context = gcUserset
  )
  adminFlagGuc = defineGucBool(
    "gucsec.admin_flag",
    "Admin toggle flag",
    "Superuser-only modifiable boolean setting",
    bootValue = false,
    context = gcSuset
  )
  secretKeyGuc = defineGucString(
    "gucsec.secret_key",
    "Superuser secret key",
    "Sensitive string hidden from non-superusers",
    bootValue = "top_secret_boot",
    context = gcSuset,
    superuserOnly = true
  )
  modeGuc = defineGucEnum(
    "gucsec.mode",
    "Execution mode",
    "Enum execution mode (fast or safe)",
    bootValue = gsmSafe,
    context = gcSuset
  )
  reserveGucPrefix("gucsec")

proc guc_max_items_native*(): int32 {.volatile.} =
  maxItemsGuc.get()

proc guc_admin_flag_native*(): bool {.volatile.} =
  adminFlagGuc.get()

proc guc_mode_native*(): string {.volatile.} =
  $modeGuc.get()

proc guc_secret_key_native*(): string {.volatile.} =
  # Gate direct backing read through restricted getGuc so non-superusers always hit 42501
  discard getGuc("gucsec.secret_key")
  secretKeyGuc.get()

proc guc_get*(name: string): Option[string] {.volatile.} =
  getGuc(name)

proc guc_set_local*(name: string, val: string): string {.volatile.} =
  setGuc(name, val, isLocal = true, allowedPrefix = "gucsec")
  result = "ok"

proc guc_set_session*(name: string, val: string): string {.volatile.} =
  setGuc(name, val, isLocal = false, allowedPrefix = "gucsec")
  result = "ok"

proc guc_set_unscoped*(name: string, val: string): string {.volatile.} =
  setGuc(name, val, isLocal = true)
  result = "ok"
