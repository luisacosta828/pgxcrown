import pgxcrown
import std/[atomics, strutils]

pgxSql("plugin_events_pre_table", """
CREATE TABLE IF NOT EXISTS plugin_events (
  id serial PRIMARY KEY,
  tag text NOT NULL,
  score int4 NOT NULL DEFAULT 0
);
""", phase = "pre")

pgxSql(
  id = "plugin_events_post_idx",
  phase = "post",
  ddl = "CREATE INDEX IF NOT EXISTS idx_plugin_events_tag ON plugin_events (tag);"
)

type
  PluginTag* {.pgxType: string.} = distinct string

  BadgeValue* {.noSql.} = object
    label*: string
    weight*: int32

var pluginInitCount*: Atomic[int32]
var pluginInitWeight*: Atomic[int32]

proc initTagPlugin() {.gcsafe.} =
  discard pluginInitCount.fetchAdd(1'i32)
  discard pluginInitWeight.fetchAdd(10'i32)

registerPgxPluginInit(initTagPlugin)

proc parse_PluginTag*(s: cstring): PluginTag {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toLowerAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "PluginTag cannot be empty")
  PluginTag(cleaned)

proc format_PluginTag*(val: PluginTag): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc pgxSqlType*(_: typedesc[PluginTag]): string {.inline.} =
  "PluginTag"

proc pgxToDatum*(val: PluginTag): Datum {.inline.} =
  returnPgText(string(val))

proc pgxFromDatum*(_: typedesc[PluginTag], d: Datum): PluginTag {.inline.} =
  PluginTag($getPgText(d))

proc toParam*(val: PluginTag): QueryParam {.inline.} =
  toParam(string(val))

proc pgxSqlType*(_: typedesc[BadgeValue]): string {.inline.} =
  "text"

proc pgxToDatum*(val: BadgeValue): Datum {.inline.} =
  returnPgText(val.label & ":" & $val.weight)

proc pgxFromDatum*(_: typedesc[BadgeValue], d: Datum): BadgeValue {.inline.} =
  let raw = $getPgText(d)
  let sep = raw.rfind(':')
  if sep < 0:
    return BadgeValue(label: raw, weight: 0'i32)
  BadgeValue(label: raw[0 ..< sep], weight: int32(parseInt(raw[sep + 1 .. ^1])))

proc toParam*(val: BadgeValue): QueryParam {.inline.} =
  toParam(val.label & ":" & $val.weight)
