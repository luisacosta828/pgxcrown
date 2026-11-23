## =============================================================================
## Reusable Plugin Type Module (`{{type_name}}`)
## =============================================================================
## How to reuse this plugin submodule across multiple pgxcrown extensions:
##   1. Copy or share `plugin_type.nim` in your extension's `src/` directory.
##   2. `import ./plugin_type` and `export plugin_type` in `src/main.nim`.
##   3. `pgx.nim` automatically discovers `pgxSql(...)` DDL blocks (`pre` table +
##      `post` index), `{.pgxType.}` INPUT/OUTPUT routines, and calls
##      `runPgxPluginInits()` inside `_PG_init` to execute `onPluginTypeInit`.
##   4. Any Binary SPI v2 `QueryBuilder` (`InsertInto`/`Select`/`fetch`) or
##      `plugin_api` bridge (`pluginSqlType`, `pluginToDatum`, `pluginFromDatum`,
##      `pluginToParam`) composes directly via the exported `mixin` contract.
## =============================================================================

import pgxcrown
import std/[atomics, strutils]

pgxSql("{{project_snake}}_audit_pre", """
CREATE TABLE IF NOT EXISTS {{project_snake}}_audit (
  id serial PRIMARY KEY,
  tag text NOT NULL
);
""", phase = "pre")

pgxSql("{{project_snake}}_audit_idx", """
CREATE INDEX IF NOT EXISTS idx_{{project_snake}}_audit_tag
  ON {{project_snake}}_audit (tag);
""", phase = "post")

type
  {{type_name}}* {.pgxType: string.} = distinct string

var pluginInitExecuted*: Atomic[bool]

proc onPluginTypeInit() {.gcsafe.} =
  pluginInitExecuted.store(true)

registerPgxPluginInit(onPluginTypeInit)

proc parse_{{type_name}}*(s: cstring): {{type_name}} {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toLowerAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "{{type_name}} cannot be empty")
  {{type_name}}(cleaned)

proc format_{{type_name}}*(val: {{type_name}}): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc pgxSqlType*(_: typedesc[{{type_name}}]): string {.inline.} =
  "{{type_name}}"

proc pgxToDatum*(val: {{type_name}}): Datum {.inline.} =
  returnPgText(string(val))

proc pgxFromDatum*(_: typedesc[{{type_name}}], d: Datum): {{type_name}} {.inline.} =
  {{type_name}}($getPgText(d))

proc toParam*(val: {{type_name}}): QueryParam {.inline.} =
  toParam(string(val))
