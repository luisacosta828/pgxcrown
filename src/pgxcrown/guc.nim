## =============================================================================
## Pgxcrown Secure GUC Management (PG 14 - 18)
## =============================================================================
## Provides ABI-safe, memory-safe, RBAC-enforced PostgreSQL GUC registration,
## prefix reservation, restricted reads, and guarded runtime updates:
##   1. Pure-Nim GUC name & prefix validation + core PostgreSQL GUC blocklist
##   2. Process-lifetime persistent storage via real_calloc (immune to ARC
##      moves/frees and PostgreSQL MemoryContextReset)
##   3. ABI-safe GUC flag & context getters via pgx_guc.h (PG 14-18 compatible)
##   4. Guarded runtime getGuc / setGuc enforcing InSecurityRestrictedOperation,
##      superuser(), pg_parameter_acl (PG 15+), and GUC_SUPERUSER_ONLY
## =============================================================================

import std/[os, strutils, math, options]
import ./compiler
import ./allocator
import ./reports/reports

const
  PgxGucCHeadersDir = currentSourcePath.parentDir / "c_headers"
  GucMaxIdentLen* = 63

{.passC: "-I" & quoteShell(PgxGucCHeadersDir).}

static:
  doAssert sizeof(cint) == sizeof(int32), "pgxcrown guc requires 32-bit cint"
  doAssert sizeof(cdouble) == sizeof(float64), "pgxcrown guc requires 64-bit cdouble"
  doAssert sizeof(bool) == 1, "pgxcrown guc requires 1-byte bool"

# =============================================================================
# Core PostgreSQL GUC Blocklist & Pure-Nim Validation
# =============================================================================

const
  BlockedCoreGucList = [
    "pg",
    "postgres",
    "postgresql",
    "shared",
    "shared_preload_libraries",
    "session_preload_libraries",
    "local_preload_libraries",
    "dynamic_library_path",
    "ssl",
    "hba_file",
    "ident_file",
    "config_file",
    "data_directory",
    "log",
    "archive",
    "restore_command",
    "listen_addresses",
    "search_path",
    "role",
    "session_authorization",
    "row_security",
    "allow_system_table_mods",
    "ignore_system_indexes",
    "jit",
    # Related security-critical / server-identity core GUCs
    "logging_collector",
    "cluster_name",
    "external_pid_file",
    "password_encryption",
    "unix_socket_directories",
    "default_transaction_read_only",
    "transaction_read_only",
    "wal_level",
    "primary_conninfo",
    "primary_slot_name",
    "recovery_target",
    "extension_destdir",
    "preload_libraries",
    "pg_catalog",
    "pg_temp",
    "pg_toast"
  ]

  BlockedCoreSingleSegmentPrefixes = [
    "pg_",
    "postgres_",
    "postgresql_",
    "shared_",
    "ssl_",
    "log_",
    "archive_",
    "jit_"
  ]

proc isInBlockedGucList(s: string): bool {.inline, noSideEffect.} =
  for item in BlockedCoreGucList:
    if s == item:
      return true
  return false

proc isValidGucSegment*(seg: string): bool {.noSideEffect.} =
  ## Validates a single GUC identifier segment against `^[a-z][a-z0-9_]*$`
  ## with PostgreSQL NAMEDATALEN-1 length limit (1..63 bytes).
  if seg.len == 0 or seg.len > GucMaxIdentLen:
    return false
  if seg[0] notin {'a'..'z'}:
    return false
  for i in 1 ..< seg.len:
    if seg[i] notin {'a'..'z', '0'..'9', '_'}:
      return false
  return true

proc hasDisallowedGucChars(s: string): bool {.inline, noSideEffect.} =
  for ch in s:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}:
      return true
  return false

proc isBlockedCoreGuc*(name: string): bool {.noSideEffect.} =
  ## Returns true if `name` targets a protected core/security-critical
  ## PostgreSQL GUC name or prefix (case-insensitive).
  if name.len == 0 or '\0' in name:
    return false
  let norm = name.strip().toLowerAscii()
  if norm.len == 0:
    return false
  let dotIdx = norm.find('.')
  if dotIdx >= 0:
    let prefix = norm[0 ..< dotIdx]
    if isInBlockedGucList(prefix):
      return true
    if prefix.startsWith("postgres"):
      return true
    return false
  else:
    if isInBlockedGucList(norm):
      return true
    for pfx in BlockedCoreSingleSegmentPrefixes:
      if norm.startsWith(pfx):
        return true
    return false

proc validateGucPrefix*(prefix: string) =
  ## Validates a custom GUC prefix segment and ensures it is not a blocked core prefix.
  if prefix.len == 0:
    raise newException(ValueError, "GUC prefix must not be empty")
  if '\0' in prefix:
    raise newException(ValueError, "GUC prefix must not contain NUL bytes")
  if hasDisallowedGucChars(prefix) or '.' in prefix:
    raise newException(ValueError,
      "Invalid GUC prefix '" & prefix & "': must match ^[a-z][a-z0-9_]*$")
  if isBlockedCoreGuc(prefix):
    raisePgError("42501", "GUC prefix '" & prefix & "' is a protected core PostgreSQL prefix")
  if not isValidGucSegment(prefix):
    raise newException(ValueError,
      "Invalid GUC prefix '" & prefix & "': must match ^[a-z][a-z0-9_]*$ (1..63 chars)")

proc validateGucName*(fullName: string, expectedPrefix: string = "") =
  ## Validates a custom GUC name in strict `<prefix>.<param>` format
  ## (`^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`, each segment <= 63 chars),
  ## rejects all protected core PostgreSQL GUCs/prefixes with SQLSTATE 42501,
  ## and enforces `expectedPrefix` when provided.
  if fullName.len == 0:
    raise newException(ValueError, "GUC name must not be empty")
  if '\0' in fullName:
    raise newException(ValueError, "GUC name must not contain NUL bytes")
  if hasDisallowedGucChars(fullName):
    raise newException(ValueError,
      "Invalid GUC name '" & fullName & "': disallowed characters (whitespace, quotes, or SQL characters)")

  if expectedPrefix.len > 0:
    validateGucPrefix(expectedPrefix)

  if isBlockedCoreGuc(fullName):
    raisePgError("42501", "GUC parameter '" & fullName & "' is a protected core PostgreSQL setting")

  let parts = fullName.split('.')
  if parts.len != 2:
    raise newException(ValueError,
      "Invalid GUC name '" & fullName & "': must be exact '<prefix>.<param>' format")

  let prefix = parts[0]
  let param = parts[1]
  if not isValidGucSegment(prefix) or not isValidGucSegment(param):
    raise newException(ValueError,
      "Invalid GUC name '" & fullName & "': segments must match ^[a-z][a-z0-9_]*$ (1..63 chars)")

  if isBlockedCoreGuc(prefix):
    raisePgError("42501", "GUC prefix '" & prefix & "' is a protected core PostgreSQL prefix")

  if expectedPrefix.len > 0 and prefix != expectedPrefix:
    raisePgError("42501",
      "GUC parameter '" & fullName & "' is outside allowed prefix '" & expectedPrefix & ".'")

proc validateGucReadName*(name: string) =
  ## Validates a GUC name passed to `getGuc`: rejects empty, NUL, whitespace,
  ## quotes, SQL characters, and malformed identifiers while permitting both
  ## `<prefix>.<param>` and single-segment GUC names for restricted PG inspection.
  if name.len == 0:
    raise newException(ValueError, "GUC name must not be empty")
  if '\0' in name:
    raise newException(ValueError, "GUC name must not contain NUL bytes")
  if hasDisallowedGucChars(name):
    raise newException(ValueError,
      "Invalid GUC name '" & name & "': disallowed characters")
  let parts = name.split('.')
  if parts.len > 2:
    raise newException(ValueError,
      "Invalid GUC name '" & name & "': at most one '.' qualifier is allowed")
  for part in parts:
    if not isValidGucSegment(part):
      raise newException(ValueError,
        "Invalid GUC name '" & name & "': invalid identifier segment '" & part & "'")

# =============================================================================
# Public Types & C Interop Declarations
# =============================================================================

type
  GucContext* = enum
    gcPostmaster
    gcSighup
    gcSuBackend
    gcBackend
    gcSuset
    gcUserset

  GucFlag* = enum
    gfSuperuserOnly
    gfNoShowAll
    gfNoResetAll
    gfReport
    gfNotWhileSecRest
    gfDisallowInFile
    gfDisallowInAutoFile

  ConfigEnumEntry* {.importc: "struct config_enum_entry", header: "utils/guc.h", bycopy.} = object
    name*: cstring
    val*: cint
    hidden*: bool

  CConstChar {.importc: "const char *", nodecl.} = distinct pointer

  GucVar*[T] = object
    ## Non-owning handle to process-lifetime PostgreSQL GUC backing storage.
    ## Backing memory is allocated via real_calloc so Nim ARC and
    ## PostgreSQL MemoryContextReset never move or free it.
    name*: string
    context*: GucContext
    superuserOnly*: bool
    readOnly*: bool
    storage*: pointer
    bootCstr*: cstring
    enumTable*: ptr ConfigEnumEntry

{.push header: "pgx_guc.h".}
proc cPgxGucFlagSuperuserOnly(): cint {.importc: "pgx_guc_flag_superuser_only".}
proc cPgxGucFlagNoShowAll(): cint {.importc: "pgx_guc_flag_no_show_all".}
proc cPgxGucFlagNoResetAll(): cint {.importc: "pgx_guc_flag_no_reset_all".}
proc cPgxGucFlagReport(): cint {.importc: "pgx_guc_flag_report".}
proc cPgxGucFlagNotWhileSecRest(): cint {.importc: "pgx_guc_flag_not_while_sec_rest".}
proc cPgxGucFlagDisallowInFile(): cint {.importc: "pgx_guc_flag_disallow_in_file".}
proc cPgxGucFlagDisallowInAutoFile(): cint {.importc: "pgx_guc_flag_disallow_in_auto_file".}

proc cPgxGucCtxPostmaster(): cint {.importc: "pgx_guc_ctx_postmaster".}
proc cPgxGucCtxSighup(): cint {.importc: "pgx_guc_ctx_sighup".}
proc cPgxGucCtxSuBackend(): cint {.importc: "pgx_guc_ctx_su_backend".}
proc cPgxGucCtxBackend(): cint {.importc: "pgx_guc_ctx_backend".}
proc cPgxGucCtxSuset(): cint {.importc: "pgx_guc_ctx_suset".}
proc cPgxGucCtxUserset(): cint {.importc: "pgx_guc_ctx_userset".}

proc cPgxGucIsPreloadInProgress(): bool {.importc: "pgx_guc_is_shared_preload_in_progress".}
proc cPgxGucInSecRestOp(): bool {.importc: "pgx_guc_in_security_restricted_operation".}
proc cPgxGucIsSuperuser(): bool {.importc: "pgx_guc_is_superuser".}

proc cPgxDefineCustomBool(
  name, shortDesc, longDesc: cstring,
  valueAddr: pointer,
  bootVal: bool,
  context, flags: cint
) {.importc: "pgx_define_custom_bool".}

proc cPgxDefineCustomInt(
  name, shortDesc, longDesc: cstring,
  valueAddr: pointer,
  bootVal, minVal, maxVal: cint,
  context, flags: cint
) {.importc: "pgx_define_custom_int".}

proc cPgxDefineCustomReal(
  name, shortDesc, longDesc: cstring,
  valueAddr: pointer,
  bootVal, minVal, maxVal: cdouble,
  context, flags: cint
) {.importc: "pgx_define_custom_real".}

proc cPgxDefineCustomString(
  name, shortDesc, longDesc: cstring,
  valueAddr: pointer,
  bootVal: cstring,
  context, flags: cint
) {.importc: "pgx_define_custom_string".}

proc cPgxDefineCustomEnum(
  name, shortDesc, longDesc: cstring,
  valueAddr: pointer,
  bootVal: cint,
  options: ptr ConfigEnumEntry,
  context, flags: cint
) {.importc: "pgx_define_custom_enum".}

proc cPgxMarkGucPrefixReserved(prefix: cstring) {.importc: "pgx_mark_guc_prefix_reserved".}
proc cPgxGetConfigOptionRestricted(name: cstring, missingOk: bool): CConstChar {.importc: "pgx_get_config_option_restricted".}
proc cPgxSetConfigOptionRbac(name, value: cstring, isLocal: bool): cint {.importc: "pgx_set_config_option_rbac".}
{.pop.}

# =============================================================================
# ABI-Safe Flag, Context & State Wrappers
# =============================================================================

proc gucFlagSuperuserOnly*(): cint {.inline.} = cPgxGucFlagSuperuserOnly()
proc gucFlagNoShowAll*(): cint {.inline.} = cPgxGucFlagNoShowAll()
proc gucFlagNoResetAll*(): cint {.inline.} = cPgxGucFlagNoResetAll()
proc gucFlagReport*(): cint {.inline.} = cPgxGucFlagReport()
proc gucFlagNotWhileSecRest*(): cint {.inline.} = cPgxGucFlagNotWhileSecRest()
proc gucFlagDisallowInFile*(): cint {.inline.} = cPgxGucFlagDisallowInFile()
proc gucFlagDisallowInAutoFile*(): cint {.inline.} = cPgxGucFlagDisallowInAutoFile()

proc isGucPreloadInProgress*(): bool {.inline.} = cPgxGucIsPreloadInProgress()
proc isGucSecurityRestricted*(): bool {.inline.} = cPgxGucInSecRestOp()
proc isGucSuperuser*(): bool {.inline.} = cPgxGucIsSuperuser()

proc toCFlags*(flags: set[GucFlag], superuserOnly: bool = false, readOnly: bool = false): cint =
  var res: cint = 0
  if superuserOnly or (gfSuperuserOnly in flags):
    res = res or cPgxGucFlagSuperuserOnly() or cPgxGucFlagNoShowAll()
  if gfNoShowAll in flags:
    res = res or cPgxGucFlagNoShowAll()
  if gfNoResetAll in flags:
    res = res or cPgxGucFlagNoResetAll()
  if gfReport in flags:
    res = res or cPgxGucFlagReport()
  if gfNotWhileSecRest in flags:
    res = res or cPgxGucFlagNotWhileSecRest()
  if readOnly or (gfDisallowInFile in flags):
    res = res or cPgxGucFlagDisallowInFile()
  if readOnly or (gfDisallowInAutoFile in flags):
    res = res or cPgxGucFlagDisallowInAutoFile()
  res

proc toCContext*(ctx: GucContext): cint =
  case ctx
  of gcPostmaster: cPgxGucCtxPostmaster()
  of gcSighup: cPgxGucCtxSighup()
  of gcSuBackend: cPgxGucCtxSuBackend()
  of gcBackend: cPgxGucCtxBackend()
  of gcSuset: cPgxGucCtxSuset()
  of gcUserset: cPgxGucCtxUserset()

# =============================================================================
# Process-Lifetime Persistent Storage (real_calloc) & ReadOnly Registry
# =============================================================================

type
  ReadOnlyGucNode = ptr ReadOnlyGucNodeObj
  ReadOnlyGucNodeObj = object
    name: cstring
    next: ReadOnlyGucNode

var readOnlyGucHead {.global.}: ReadOnlyGucNode = nil

proc allocPersistentZeroed(nmemb, size: csize_t): pointer =
  let p = real_calloc(nmemb, size)
  if p == nil:
    raisePgError(ERRCODE_OUT_OF_MEMORY, "Out of memory allocating persistent GUC storage")
  return p

proc allocPersistentCStr(s: string): cstring =
  let buf = allocPersistentZeroed(csize_t(s.len + 1), 1.csize_t)
  if s.len > 0:
    copyMem(buf, unsafeAddr s[0], s.len)
  return cast[cstring](buf)

proc allocPersistentLongDesc(s: string): cstring =
  if s.len == 0:
    return nil
  return allocPersistentCStr(s)

proc markGucReadOnly(name: string) =
  let node = cast[ReadOnlyGucNode](allocPersistentZeroed(1.csize_t, csize_t(sizeof(ReadOnlyGucNodeObj))))
  node.name = allocPersistentCStr(name)
  node.next = readOnlyGucHead
  readOnlyGucHead = node

proc isGucReadOnly*(name: string): bool =
  var cur = readOnlyGucHead
  while cur != nil:
    if cur.name != nil and $cur.name == name:
      return true
    cur = cur.next
  return false

proc buildPersistentEnumEntries*[E: enum](
  options: openArray[(string, E, bool)] = @[]
): ptr ConfigEnumEntry =
  ## Builds a process-lifetime, NULL-terminated `struct config_enum_entry` array
  ## via `real_calloc` so neither Nim ARC nor PostgreSQL MemoryContextReset can move/free it.
  var items: seq[(string, E, bool)] = @[]
  if options.len > 0:
    for opt in options:
      items.add(opt)
  else:
    for e in E:
      items.add(($e, e, false))

  if items.len == 0:
    raise newException(ValueError, "Enum GUC must define at least one option")

  for (label, val, _) in items:
    if label.len == 0 or '\0' in label:
      raise newException(ValueError, "Enum GUC option label must be non-empty and NUL-free")
    let rawOrd = ord(val)
    if rawOrd < int(cint.low) or rawOrd > int(cint.high):
      raise newException(ValueError, "Enum GUC ordinal out of 32-bit C int range")

  let arr = cast[ptr UncheckedArray[ConfigEnumEntry]](
    allocPersistentZeroed(csize_t(items.len + 1), csize_t(sizeof(ConfigEnumEntry)))
  )
  for i, (label, val, isHidden) in items:
    arr[i].name = allocPersistentCStr(label)
    arr[i].val = cint(ord(val))
    arr[i].hidden = isHidden
  # Final element arr[items.len] is already zeroed by real_calloc: {NULL, 0, false}
  return cast[ptr ConfigEnumEntry](arr)

proc freePersistentEnumEntries*(table: ptr ConfigEnumEntry) =
  ## Frees a persistent `config_enum_entry` array created for unit tests.
  ## Do NOT call on tables registered with PostgreSQL (`DefineCustomEnumVariable`).
  if table == nil:
    return
  let arr = cast[ptr UncheckedArray[ConfigEnumEntry]](table)
  var i = 0
  while arr[i].name != nil:
    real_free(cast[pointer](arr[i].name))
    inc i
  real_free(cast[pointer](table))

# =============================================================================
# Runtime RBAC Read / Write Helpers
# =============================================================================

proc getGuc*(name: string): Option[string] =
  ## Safely inspects a PostgreSQL GUC option using `GetConfigOption(name, true, true)`
  ## inside `pgTry`. Enforces `GUC_SUPERUSER_ONLY` (re-raises SQLSTATE 42501 as PgError)
  ## and returns `none(string)` only when the GUC does not exist.
  validateGucReadName(name)
  var found = false
  var valStr = ""
  try:
    pgTry:
      let raw = cPgxGetConfigOptionRestricted(cstring(name), true)
      let cstr = cast[cstring](raw)
      if cstr != nil:
        found = true
        valStr = $cstr
  except PostgresError as e:
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  if not found:
    return none(string)
  return some(valStr)

proc setGuc*(name: string, value: string, isLocal: bool = true, allowedPrefix: string = "") =
  ## Safely updates a custom GUC option using RBAC-guarded `pgx_set_config_option_rbac`
  ## inside `pgTry`. Rejects blocked core GUCs, names outside `allowedPrefix & "."`,
  ## read-only GUCs, and embedded NUL bytes BEFORE calling PostgreSQL C APIs.
  validateGucName(name, allowedPrefix)
  if '\0' in value:
    raise newException(ValueError, "GUC value must not contain NUL bytes")
  if isGucReadOnly(name):
    raisePgError("42501", "GUC parameter '" & name & "' is read-only")
  try:
    pgTry:
      discard cPgxSetConfigOptionRbac(cstring(name), cstring(value), isLocal)
  except PostgresError as e:
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)

# =============================================================================
# GucVar[T] Accessors & Safe Mutators
# =============================================================================

proc isInitialized*[T](v: GucVar[T]): bool {.inline.} =
  v.storage != nil

proc get*[T](v: GucVar[T]): T =
  ## Reads the current value from PostgreSQL's persistent GUC backing variable.
  if v.storage == nil:
    raise newException(ValueError, "GucVar '" & v.name & "' is not initialized")
  when T is bool:
    return cast[ptr bool](v.storage)[]
  elif T is int32:
    return int32(cast[ptr cint](v.storage)[])
  elif T is cint:
    return cast[ptr cint](v.storage)[]
  elif T is int:
    return int(cast[ptr cint](v.storage)[])
  elif T is float64:
    return float64(cast[ptr cdouble](v.storage)[])
  elif T is cdouble:
    return cast[ptr cdouble](v.storage)[]
  elif T is float32:
    return float32(cast[ptr cdouble](v.storage)[])
  elif T is string:
    let cstr = cast[ptr cstring](v.storage)[]
    if cstr == nil:
      return ""
    return $cstr
  elif T is enum:
    let raw = cast[ptr cint](v.storage)[]
    for e in T:
      if cint(ord(e)) == raw:
        return e
    raise newException(ValueError, "GucVar '" & v.name & "' holds invalid enum ordinal: " & $raw)
  else:
    {.error: "Unsupported GucVar[T] type".}

proc value*[T](v: GucVar[T]): T {.inline.} =
  v.get()

proc `[]`*[T](v: GucVar[T]): T {.inline.} =
  v.get()

proc gucValueToString[T](v: GucVar[T], val: T): string =
  when T is bool:
    if val: "on" else: "off"
  elif T is SomeSignedInt or T is cint:
    $val
  elif T is SomeFloat or T is cdouble:
    $val
  elif T is string:
    val
  elif T is enum:
    if v.enumTable != nil:
      let arr = cast[ptr UncheckedArray[ConfigEnumEntry]](v.enumTable)
      let targetOrd = cint(ord(val))
      var i = 0
      while arr[i].name != nil:
        if arr[i].val == targetOrd:
          return $arr[i].name
        inc i
    $val
  else:
    {.error: "Unsupported GucVar[T] type".}

proc set*[T](v: GucVar[T], val: T, isLocal: bool = true) =
  ## Mutates the GUC through RBAC-enforced `setGuc` (respects PG GUC stack,
  ## `SET LOCAL` / `ROLLBACK`, `superuser()`, `InSecurityRestrictedOperation()`, and `readOnly`).
  if v.storage == nil:
    raise newException(ValueError, "GucVar '" & v.name & "' is not initialized")
  if v.readOnly:
    raisePgError("42501", "GUC parameter '" & v.name & "' is read-only")
  setGuc(v.name, v.gucValueToString(val), isLocal = isLocal)

proc `value=`*[T](v: GucVar[T], val: T) {.inline.} =
  v.set(val, isLocal = true)

proc `[]=`*[T](v: GucVar[T], val: T) {.inline.} =
  v.set(val, isLocal = true)

# =============================================================================
# Typed GUC Constructors for {.pgxInit.} / shared_preload_libraries
# =============================================================================

type
  GucDefineCArgs = object
    cName: cstring
    cShort: cstring
    cLong: cstring
    cFlags: cint
    cCtx: cint

proc validateDefineCommon(
  name, shortDesc, longDesc: string,
  context: GucContext,
  superuserOnly: bool,
  flags: set[GucFlag]
) =
  validateGucName(name)
  if '\0' in shortDesc or '\0' in longDesc:
    raise newException(ValueError, "GUC descriptions must not contain NUL bytes")
  if (superuserOnly or gfSuperuserOnly in flags) and context in {gcUserset, gcBackend}:
    raise newException(ValueError,
      "superuserOnly / gfSuperuserOnly cannot be combined with gcUserset or gcBackend context")
  if context == gcPostmaster and not isGucPreloadInProgress():
    raise newException(ValueError,
      "gcPostmaster GUC '" & name & "' requires loading via shared_preload_libraries")

proc prepareGucDefineCArgs(
  name, shortDesc, longDesc: string,
  context: GucContext,
  superuserOnly: bool,
  flags: set[GucFlag],
  readOnly: bool
): GucDefineCArgs =
  validateDefineCommon(name, shortDesc, longDesc, context, superuserOnly, flags)
  result = GucDefineCArgs(
    cName: allocPersistentCStr(name),
    cShort: allocPersistentCStr(shortDesc),
    cLong: allocPersistentLongDesc(longDesc),
    cFlags: toCFlags(flags, superuserOnly, readOnly),
    cCtx: toCContext(context)
  )

proc freeGucDefineCArgs(args: GucDefineCArgs, storage: pointer) =
  if storage != nil: real_free(storage)
  if args.cName != nil: real_free(cast[pointer](args.cName))
  if args.cShort != nil: real_free(cast[pointer](args.cShort))
  if args.cLong != nil: real_free(cast[pointer](args.cLong))

proc makeGucVar[T](
  name: string,
  context: GucContext,
  superuserOnly: bool,
  flags: set[GucFlag],
  readOnly: bool,
  storage: pointer,
  bootCstr: cstring = nil,
  enumTable: ptr ConfigEnumEntry = nil
): GucVar[T] =
  if readOnly:
    markGucReadOnly(name)
  GucVar[T](
    name: name,
    context: context,
    superuserOnly: superuserOnly or (gfSuperuserOnly in flags),
    readOnly: readOnly,
    storage: storage,
    bootCstr: bootCstr,
    enumTable: enumTable
  )

proc defineGucBool*(
  name: string,
  shortDesc: string,
  longDesc: string = "",
  bootValue: bool = false,
  context: GucContext = gcSuset,
  superuserOnly: bool = false,
  flags: set[GucFlag] = {},
  readOnly: bool = false
): GucVar[bool] =
  let args = prepareGucDefineCArgs(name, shortDesc, longDesc, context, superuserOnly, flags, readOnly)
  let storage = allocPersistentZeroed(1.csize_t, csize_t(sizeof(bool)))
  cast[ptr bool](storage)[] = bootValue
  try:
    pgTry:
      cPgxDefineCustomBool(args.cName, args.cShort, args.cLong, storage, bootValue, args.cCtx, args.cFlags)
  except PostgresError as e:
    freeGucDefineCArgs(args, storage)
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  makeGucVar[bool](name, context, superuserOnly, flags, readOnly, storage)

proc defineGucInt*[I: SomeSignedInt | cint](
  name: string,
  shortDesc: string,
  longDesc: string,
  bootValue: I,
  minVal: I,
  maxVal: I,
  context: GucContext = gcSuset,
  superuserOnly: bool = false,
  flags: set[GucFlag] = {},
  readOnly: bool = false
): GucVar[int32] =
  let boot64 = int64(bootValue)
  let min64 = int64(minVal)
  let max64 = int64(maxVal)
  if boot64 < int64(cint.low) or boot64 > int64(cint.high) or
     min64 < int64(cint.low) or min64 > int64(cint.high) or
     max64 < int64(cint.low) or max64 > int64(cint.high):
    raise newException(ValueError, "Integer GUC value/bounds must fit within 32-bit C int")
  if min64 > max64:
    raise newException(ValueError, "GUC minVal (" & $min64 & ") must be <= maxVal (" & $max64 & ")")
  if boot64 < min64 or boot64 > max64:
    raise newException(ValueError,
      "GUC bootValue (" & $boot64 & ") must lie within [" & $min64 & ", " & $max64 & "]")

  let args = prepareGucDefineCArgs(name, shortDesc, longDesc, context, superuserOnly, flags, readOnly)
  let storage = allocPersistentZeroed(1.csize_t, csize_t(sizeof(cint)))
  cast[ptr cint](storage)[] = cint(boot64)
  try:
    pgTry:
      cPgxDefineCustomInt(args.cName, args.cShort, args.cLong, storage, cint(boot64), cint(min64), cint(max64), args.cCtx, args.cFlags)
  except PostgresError as e:
    freeGucDefineCArgs(args, storage)
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  makeGucVar[int32](name, context, superuserOnly, flags, readOnly, storage)

proc defineGucReal*[F: SomeFloat | cdouble](
  name: string,
  shortDesc: string,
  longDesc: string,
  bootValue: F,
  minVal: F,
  maxVal: F,
  context: GucContext = gcSuset,
  superuserOnly: bool = false,
  flags: set[GucFlag] = {},
  readOnly: bool = false
): GucVar[float64] =
  let bootF = float64(bootValue)
  let minF = float64(minVal)
  let maxF = float64(maxVal)
  if classify(bootF) in {fcNan, fcInf, fcNegInf} or
     classify(minF) in {fcNan, fcInf, fcNegInf} or
     classify(maxF) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Real GUC bootValue, minVal, and maxVal must be finite")
  if minF > maxF:
    raise newException(ValueError, "GUC minVal (" & $minF & ") must be <= maxVal (" & $maxF & ")")
  if bootF < minF or bootF > maxF:
    raise newException(ValueError,
      "GUC bootValue (" & $bootF & ") must lie within [" & $minF & ", " & $maxF & "]")

  let args = prepareGucDefineCArgs(name, shortDesc, longDesc, context, superuserOnly, flags, readOnly)
  let storage = allocPersistentZeroed(1.csize_t, csize_t(sizeof(cdouble)))
  cast[ptr cdouble](storage)[] = cdouble(bootF)
  try:
    pgTry:
      cPgxDefineCustomReal(args.cName, args.cShort, args.cLong, storage, cdouble(bootF), cdouble(minF), cdouble(maxF), args.cCtx, args.cFlags)
  except PostgresError as e:
    freeGucDefineCArgs(args, storage)
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  makeGucVar[float64](name, context, superuserOnly, flags, readOnly, storage)

proc defineGucString*(
  name: string,
  shortDesc: string,
  longDesc: string = "",
  bootValue: string = "",
  context: GucContext = gcSuset,
  superuserOnly: bool = false,
  flags: set[GucFlag] = {},
  readOnly: bool = false
): GucVar[string] =
  if '\0' in bootValue:
    raise newException(ValueError, "String GUC bootValue must not contain NUL bytes")

  let args = prepareGucDefineCArgs(name, shortDesc, longDesc, context, superuserOnly, flags, readOnly)
  # DefineCustomStringVariable requires *valueAddr == NULL initially and stores bootValue directly as boot_val
  let storage = allocPersistentZeroed(1.csize_t, csize_t(sizeof(cstring)))
  let cBoot = allocPersistentCStr(bootValue)
  try:
    pgTry:
      cPgxDefineCustomString(args.cName, args.cShort, args.cLong, storage, cBoot, args.cCtx, args.cFlags)
  except PostgresError as e:
    real_free(cast[pointer](cBoot))
    freeGucDefineCArgs(args, storage)
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  makeGucVar[string](name, context, superuserOnly, flags, readOnly, storage, bootCstr = cBoot)

proc defineGucEnum*[E: enum](
  name: string,
  shortDesc: string,
  longDesc: string,
  bootValue: E,
  context: GucContext = gcSuset,
  superuserOnly: bool = false,
  flags: set[GucFlag] = {},
  readOnly: bool = false,
  options: openArray[(string, E, bool)] = @[]
): GucVar[E] =
  validateDefineCommon(name, shortDesc, longDesc, context, superuserOnly, flags)
  let table = buildPersistentEnumEntries[E](options)
  let bootOrd = cint(ord(bootValue))
  var bootFound = false
  let arr = cast[ptr UncheckedArray[ConfigEnumEntry]](table)
  var idx = 0
  while arr[idx].name != nil:
    if arr[idx].val == bootOrd:
      bootFound = true
      break
    inc idx
  if not bootFound:
    freePersistentEnumEntries(table)
    raise newException(ValueError, "Enum GUC bootValue is not present in enum options table")

  let args = prepareGucDefineCArgs(name, shortDesc, longDesc, context, superuserOnly, flags, readOnly)
  let storage = allocPersistentZeroed(1.csize_t, csize_t(sizeof(cint)))
  cast[ptr cint](storage)[] = bootOrd
  try:
    pgTry:
      cPgxDefineCustomEnum(args.cName, args.cShort, args.cLong, storage, bootOrd, table, args.cCtx, args.cFlags)
  except PostgresError as e:
    freePersistentEnumEntries(table)
    freeGucDefineCArgs(args, storage)
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
  makeGucVar[E](name, context, superuserOnly, flags, readOnly, storage, enumTable = table)

proc reserveGucPrefix*(prefix: string) =
  ## Reserves a custom GUC prefix (calls MarkGUCPrefixReserved on PG 15+,
  ## EmitWarningsOnPlaceholders on PG 14) after all prefix variables are defined.
  validateGucPrefix(prefix)
  let cPrefix = allocPersistentCStr(prefix)
  try:
    pgTry:
      cPgxMarkGucPrefixReserved(cPrefix)
  except PostgresError as e:
    real_free(cast[pointer](cPrefix))
    raise newPgError(e.sqlerrcode, e.msg, e.detail, e.hint, e.context)
