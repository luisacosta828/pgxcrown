import pgxcrown
import std/[atomics, strutils]

pgxSql("ex12_audit_pre_table", """
CREATE TABLE IF NOT EXISTS ex12_audit_log (
  id serial PRIMARY KEY,
  tag text NOT NULL,
  detail text
);
""", phase = "pre")

pgxSql("ex12_audit_post_idx", """
CREATE INDEX IF NOT EXISTS idx_ex12_audit_tag
  ON ex12_audit_log (tag);
""", phase = "post")

type
  Ex12AuditTag* {.pgxType: string.} = distinct string

var gEx12PluginInitCount*: Atomic[int32]

proc onEx12PluginInit() {.gcsafe.} =
  discard gEx12PluginInitCount.fetchAdd(1'i32)

registerPgxPluginInit(onEx12PluginInit)

proc parse_Ex12AuditTag*(s: cstring): Ex12AuditTag {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toLowerAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "Ex12AuditTag cannot be empty")
  Ex12AuditTag(cleaned)

proc format_Ex12AuditTag*(val: Ex12AuditTag): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

# Stable mixin plugin type contract consumed by plugin_api.nim bridges
proc pgxSqlType*(_: typedesc[Ex12AuditTag]): string {.inline.} =
  "Ex12AuditTag"

proc pgxToDatum*(val: Ex12AuditTag): Datum {.inline.} =
  returnPgText(string(val))

proc pgxFromDatum*(_: typedesc[Ex12AuditTag], d: Datum): Ex12AuditTag {.inline.} =
  Ex12AuditTag($getPgText(d))

proc toParam*(val: Ex12AuditTag): QueryParam {.inline.} =
  toParam(string(val))
