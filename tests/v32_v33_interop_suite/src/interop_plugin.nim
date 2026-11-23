import pgxcrown
import std/[atomics, strutils]

pgxSql("interop_events_pre_table", """
CREATE TABLE IF NOT EXISTS interop_events (
  id serial PRIMARY KEY,
  tag text NOT NULL,
  note text,
  qty int4 NOT NULL DEFAULT 0
);
""", phase = "pre")

pgxSql("interop_events_post_idx", """
CREATE INDEX IF NOT EXISTS idx_interop_events_tag
  ON interop_events (tag);
""", phase = "post")

type
  InteropTag* {.pgxType: string.} = distinct string

var gPluginInitRuns*: Atomic[int32]

proc onInteropPluginInit() {.gcsafe.} =
  discard gPluginInitRuns.fetchAdd(1'i32)

registerPgxPluginInit(onInteropPluginInit)

proc parse_InteropTag*(s: cstring): InteropTag {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toLowerAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "InteropTag cannot be empty")
  InteropTag(cleaned)

proc format_InteropTag*(val: InteropTag): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc pgxSqlType*(_: typedesc[InteropTag]): string {.inline.} =
  "InteropTag"

proc pgxToDatum*(val: InteropTag): Datum {.inline.} =
  returnPgText(string(val))

proc pgxFromDatum*(_: typedesc[InteropTag], d: Datum): InteropTag {.inline.} =
  InteropTag($getPgText(d))

proc toParam*(val: InteropTag): QueryParam {.inline.} =
  toParam(string(val))
