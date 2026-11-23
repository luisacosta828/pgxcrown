import pgxcrown
import std/atomics
import ./plugin_type

export plugin_type

type
  PluginAuditRow {.noSql.} = object
    id*: int32
    tag*: {{type_name}}

proc {{project_snake}}_plugin_ready*(): bool {.volatile.} =
  pluginInitExecuted.load()

proc {{project_snake}}_plugin_meta*(val: {{type_name}}): string {.immutable, parallelSafe.} =
  let sqlTy = pluginSqlType({{type_name}})
  let d = pluginToDatum(val)
  let roundtrip = pluginFromDatum({{type_name}}, d)
  let qp = pluginToParam(roundtrip)
  "type=" & sqlTy & "|roundtrip=" & string(roundtrip) & "|param=" & $qp

proc {{project_snake}}_audit_insert*(tag: {{type_name}}): int64 {.volatile.} =
  let t = table("{{project_snake}}_audit")
  InsertInto(t, t.tag)
    .Values(pluginToParam(tag))
    .Returning("id")
    .scalar(int64)

proc {{project_snake}}_audit_count*(tag: {{type_name}}): int64 {.volatile.} =
  let t = table("{{project_snake}}_audit")
  let rows = Select(t.id, t.tag)
    .From(t)
    .Where(t.tag == pluginToParam(tag))
    .OrderBy(t.id.asc)
    .fetch(PluginAuditRow)
  int64(rows.len)
