## =============================================================================
## Pgxcrown Plugin & Extensibility API
## =============================================================================
## Provides:
##   1. Compile-time declarative SQL block hook: `pgxSql(id, ddl, phase = "post")`
##   2. Stable `mixin` plugin type contract (`pgxSqlType`, `pgxToDatum`,
##      `pgxFromDatum`, `toParam`) and typed generic bridges
##   3. ARC- and `--wrap=malloc`-safe plugin initialization hook registry
##      executed cleanly during PostgreSQL `_PG_init`
## =============================================================================

import std/[macros, strutils]
import ./datatypes/basic
import ./query_builder

export Datum, QueryParam, ParamKind, toParam

macro pgxSql*(id: static[string], ddl: static[string], phase: static[string] = "post"): untyped =
  ## Declarative compile-time SQL block hook parsed by `pgxcrown/pgx`.
  ##
  ## Parameters:
  ## - `id`: unique non-empty identifier across all extension modules.
  ## - `ddl`: SQL DDL statement(s) emitted into `<ext>.sql`, `<ext>--<ver>.sql`,
  ##          and the structured schema snapshot.
  ## - `phase`: `"pre"` (emitted before extension types and routines) or
  ##            `"post"` (emitted after extension routines; default).
  ##
  ## Expands to an empty statement list during normal Nim compilation.
  if id.strip().len == 0 or '\0' in id:
    error("pgxSql 'id' must be non-empty and cannot contain NUL bytes")
  if ddl.strip().len == 0 or '\0' in ddl:
    error("pgxSql 'ddl' must be non-empty and cannot contain NUL bytes")
  if phase notin ["pre", "post"] or '\0' in phase:
    error("pgxSql 'phase' must be \"pre\" or \"post\", got '" & phase & "'")
  newStmtList()

# =============================================================================
# Stable `mixin` Plugin Type Contract & Typed Generic Bridges
# =============================================================================
#
# Plugin modules extending pgxcrown with a custom Nim type `T` should define
# and export the following contract procedures:
#
#   proc pgxSqlType*(_: typedesc[T]): string
#     Returns the PostgreSQL SQL type name for `T` (e.g. `"my_type"` or `"text"`).
#
#   proc pgxToDatum*(val: T): Datum
#     Serializes a value of type `T` into a PostgreSQL `Datum`.
#
#   proc pgxFromDatum*(_: typedesc[T], d: Datum): T
#     Deserializes a PostgreSQL `Datum` back into a value of type `T`.
#
#   proc toParam*(val: T): QueryParam
#     Encodes a value of type `T` into a `QueryParam` for `query_builder`.

proc pluginSqlType*[T](t: typedesc[T]): string {.inline.} =
  ## Typed generic bridge resolving the PostgreSQL SQL type name for `T`
  ## via the user/plugin-defined `pgxSqlType` mixin contract.
  mixin pgxSqlType
  pgxSqlType(t)

proc pluginSqlType*[T](): string {.inline.} =
  ## Convenience zero-argument bridge `pluginSqlType[T]()` delegating to `pgxSqlType(T)`.
  mixin pgxSqlType
  pgxSqlType(T)

proc pluginToDatum*[T](val: T): Datum {.inline.} =
  ## Typed generic bridge converting a plugin value `val: T` into a PostgreSQL `Datum`
  ## via the user/plugin-defined `pgxToDatum` mixin contract.
  mixin pgxToDatum
  pgxToDatum(val)

proc pluginFromDatum*[T](t: typedesc[T], d: Datum): T {.inline.} =
  ## Typed generic bridge decoding a PostgreSQL `Datum` into plugin type `T`
  ## via the user/plugin-defined `pgxFromDatum` mixin contract.
  mixin pgxFromDatum
  pgxFromDatum(t, d)

proc pluginFromDatum*[T](d: Datum): T {.inline.} =
  ## Convenience generic bridge `pluginFromDatum[T](d)` delegating to `pgxFromDatum(T, d)`.
  mixin pgxFromDatum
  pgxFromDatum(T, d)

proc pluginFromDatum*[T](d: Datum, t: typedesc[T]): T {.inline.} =
  ## Convenience generic bridge `pluginFromDatum(d, T)` delegating to `pgxFromDatum(t, d)`.
  mixin pgxFromDatum
  pgxFromDatum(t, d)

proc pluginToParam*[T](val: T): QueryParam {.inline.} =
  ## Typed generic bridge encoding a plugin value `val: T` into a `QueryParam`
  ## via the user/plugin-defined `toParam` mixin contract.
  mixin toParam
  toParam(val)

proc toQueryParam*(p: QueryParam): QueryParam {.inline.} =
  ## Identity bridge allowing `QueryParam` values (e.g. from `pluginToParam`) to mix
  ## freely with typed values inside `varargs[QueryParam, toQueryParam]` DSL calls.
  p

# =============================================================================
# Plugin Initialization Hook Registry (Fixed-Size Static Array, ARC-Safe)
# =============================================================================

const MAX_PGX_PLUGIN_INITS* = 64

type
  PgxPluginInitCallback* = proc() {.gcsafe.}

  PgxPluginInitEntry = object
    cb: PgxPluginInitCallback
    ran: bool

var
  pgxPluginInits {.global.}: array[MAX_PGX_PLUGIN_INITS, PgxPluginInitEntry]
  pgxPluginInitCount* {.global.}: int = 0

proc resetPgxPluginInits*() =
  ## Clears all registered plugin initialization callbacks (intended for unit tests).
  for i in 0 ..< MAX_PGX_PLUGIN_INITS:
    pgxPluginInits[i] = PgxPluginInitEntry(cb: nil, ran: false)
  pgxPluginInitCount = 0

proc registerPgxPluginInit*(cb: proc() {.gcsafe.}) =
  ## Registers a plugin initialization callback to execute during PostgreSQL `_PG_init`.
  ## Backed by a fixed-size static array so top-level calls during `NimMain` are
  ## safe under `--mm:arc` and `--wrap=malloc`.
  if cb == nil:
    return
  if pgxPluginInitCount >= MAX_PGX_PLUGIN_INITS:
    raise newException(Defect,
      "Exceeded MAX_PGX_PLUGIN_INITS (" & $MAX_PGX_PLUGIN_INITS & ")")
  pgxPluginInits[pgxPluginInitCount] = PgxPluginInitEntry(cb: cb, ran: false)
  inc pgxPluginInitCount

proc runPgxPluginInits*() =
  ## Idempotently executes all registered plugin initialization callbacks that have
  ## not yet run in the current backend process.
  var idx = 0
  while idx < pgxPluginInitCount:
    if not pgxPluginInits[idx].ran and pgxPluginInits[idx].cb != nil:
      pgxPluginInits[idx].ran = true
      pgxPluginInits[idx].cb()
    inc idx
