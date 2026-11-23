import pgxcrown
import std/[atomics, options, strutils]
import ./audit_plugin

export audit_plugin

pgxSql("ex12_audit_post_view", """
CREATE OR REPLACE VIEW ex12_audit_summary AS
SELECT tag,
       count(*)::bigint AS entry_count,
       ex12_describe_tag(tag::"Ex12AuditTag") AS tag_meta
FROM ex12_audit_log
GROUP BY tag;
""", phase = "post")

type
  Ex12AuditRow {.noSql.} = object
    id*: int32
    tag*: Ex12AuditTag
    detail*: Option[string]

proc ex12_plugin_ready*(): bool {.volatile.} =
  ## Verifies _PG_init automatically ran registerPgxPluginInit callbacks idempotently.
  runPgxPluginInits()
  gEx12PluginInitCount.load() == 1'i32

proc ex12_describe_tag*(tag: Ex12AuditTag): string {.immutable, parallelSafe.} =
  ## Exercises pluginSqlType, pluginToDatum, pluginFromDatum, and pluginToParam bridges.
  let sqlTy = pluginSqlType(Ex12AuditTag)
  let d = pluginToDatum(tag)
  let roundtrip = pluginFromDatum(Ex12AuditTag, d)
  let qp = pluginToParam(roundtrip)
  "sql=" & sqlTy & "|val=" & string(roundtrip) & "|param=" & $qp

proc ex12_record_audit*(tag: Ex12AuditTag, detail: Option[string]): int64 {.volatile.} =
  ## Uses Binary SPI v2 QueryBuilder with pluginToParam(tag) and Option[string].
  let t = table("ex12_audit_log")
  InsertInto(t, t.tag, t.detail)
    .Values(pluginToParam(tag), detail)
    .Returning("id")
    .scalar(int64)

proc ex12_fetch_audit*(tag: Ex12AuditTag): string {.volatile.} =
  ## Fetches typed rows decoding Ex12AuditTag + Option[string] via Binary SPI v2.
  let t = table("ex12_audit_log")
  let rows = Select(t.id, t.tag, t.detail)
    .From(t)
    .Where(t.tag == pluginToParam(tag))
    .OrderBy(t.id.asc)
    .fetch(Ex12AuditRow)
  var parts: seq[string] = @[]
  for r in rows:
    let dTag =
      if r.detail.isNone: "NULL"
      elif r.detail.get.len == 0: "EMPTY"
      else: "SOME(" & r.detail.get & ")"
    parts.add($r.id & ":" & string(r.tag) & ":" & dTag)
  parts.join("|")
