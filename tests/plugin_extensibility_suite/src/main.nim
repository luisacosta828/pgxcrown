import pgxcrown
import std/[atomics, strutils]
import ./tag_plugin

export tag_plugin

pgxSql("main_pre_audit_table", """
CREATE TABLE IF NOT EXISTS plugin_audit_meta (
  k text PRIMARY KEY,
  v text NOT NULL
);
""", "pre")

pgxSql "main_post_view", """
CREATE OR REPLACE VIEW plugin_event_summary AS
SELECT tag,
       count(*)::bigint AS total_events,
       coalesce(sum(score), 0)::bigint AS total_score,
       pe_describe_tag(tag::"PluginTag") AS tag_meta
FROM plugin_events
GROUP BY tag;
"""

proc initMainPluginHook() {.gcsafe.} =
  discard pluginInitCount.fetchAdd(1'i32)
  discard pluginInitWeight.fetchAdd(5'i32)

registerPgxPluginInit(initMainPluginHook)

# NOTE: Intentionally NO {.pgxInit.} proc and NO {.pgxShared.} vars in main.nim!
# Automatic _PG_init emitted by pgx.nim must still execute runPgxPluginInits().

proc pe_init_status*(): string {.volatile.} =
  let beforeCnt = pluginInitCount.load()
  let beforeW = pluginInitWeight.load()
  runPgxPluginInits() # must be idempotent
  let afterCnt = pluginInitCount.load()
  let afterW = pluginInitWeight.load()
  "before=" & $beforeCnt & "/" & $beforeW & "|after=" & $afterCnt & "/" & $afterW

proc pe_describe_tag*(tag: PluginTag): string {.immutable, parallelSafe.} =
  let sqlTy = pluginSqlType(PluginTag)
  let d = pluginToDatum(tag)
  let roundtrip = pluginFromDatum(PluginTag, d)
  let qp = pluginToParam(roundtrip)
  "sql=" & sqlTy & "|val=" & string(roundtrip) & "|param=" & $qp

proc pe_badge_roundtrip*(label: string, weight: int32): string {.immutable, parallelSafe.} =
  let b = BadgeValue(label: label, weight: weight)
  let sqlTy = pluginSqlType[BadgeValue]()
  let d = pluginToDatum(b)
  let roundtrip = pluginFromDatum[BadgeValue](d)
  let qp = pluginToParam(roundtrip)
  "sql=" & sqlTy & "|label=" & roundtrip.label & "|weight=" & $roundtrip.weight & "|param=" & $qp

proc pe_record_event*(tag: PluginTag, score: int32): int32 {.volatile.} =
  let t = table("plugin_events")
  discard InsertInto(t, t.tag, t.score).Values(pluginToParam(tag), score).run()
  let rows = Select(raw("count(*)::int4") as "cnt").From(t).Where(t.tag == pluginToParam(tag)).rows()
  if rows.len > 0:
    return int32(parseInt(rows[0]["cnt"]))
  0'i32

proc pe_seed_meta*(k, v: string): string {.volatile.} =
  let t = table("plugin_audit_meta")
  discard InsertInto(t, t.k, t.v)
    .Values(k, v)
    .OnConflict("k")
    .DoUpdate(t.v, toParam(v))
    .run()
  let rows = Select(t.v).From(t).Where(t.k == k).rows()
  if rows.len > 0:
    return rows[0]["v"]
  return ""
