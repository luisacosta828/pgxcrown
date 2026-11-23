import pgxcrown
import std/[options, strutils]

pgxSql("{{project_snake}}_items_table", """
CREATE TABLE IF NOT EXISTS {{project_snake}}_items (
  id serial PRIMARY KEY,
  label text NOT NULL,
  payload text
);
""", phase = "pre")

pgxSql("{{project_snake}}_items_label_idx", """
CREATE INDEX IF NOT EXISTS idx_{{project_snake}}_items_label
  ON {{project_snake}}_items (label);
""", phase = "post")

type
  ServiceItemRow {.noSql.} = object
    id*: int32
    label*: string
    payload*: Option[string]

var
  gMaxLimitGuc: GucVar[int32]
  gStrictModeGuc: GucVar[bool]
  gCommittedOps {.global.}: int64 = 0
  gAbortedOps {.global.}: int64 = 0

proc {{project_snake}}_service_init*() {.pgxInit.} =
  gMaxLimitGuc = defineGucInt(
    "{{guc_prefix}}.max_limit",
    "Maximum rows returned by {{project_name}} queries",
    "User-configurable bounded query limit",
    bootValue = 100,
    minVal = 1,
    maxVal = 10000,
    context = gcUserset
  )
  gStrictModeGuc = defineGucBool(
    "{{guc_prefix}}.strict_mode",
    "Enable strict label validation",
    "Superuser-only strict input validation policy",
    bootValue = true,
    context = gcSuset
  )
  reserveGucPrefix("{{guc_prefix}}")

proc {{project_snake}}_policy_status*(): string {.volatile.} =
  "max_limit=" & $gMaxLimitGuc.get() & "|strict_mode=" & $gStrictModeGuc.get()

proc {{project_snake}}_record*(label: string, payload: Option[string] = none(string)): int64 {.volatile.} =
  if gStrictModeGuc.get() and label.strip().len == 0:
    raisePgError("22023", "label cannot be empty when {{guc_prefix}}.strict_mode is enabled")

  let t = table("{{project_snake}}_items")
  let insertedId = InsertInto(t, t.label, t.payload)
    .Values(label, payload)
    .Returning("id")
    .scalar(int64)

  discard onCommit(proc() = inc gCommittedOps, once = true)
  discard onAbort(proc() = inc gAbortedOps, once = true)
  insertedId

proc {{project_snake}}_fetch_summary*(): string {.volatile.} =
  let t = table("{{project_snake}}_items")
  let limitVal = int(gMaxLimitGuc.get())
  let rows = Select(t.id, t.label, t.payload)
    .From(t)
    .OrderBy(t.id.asc)
    .Limit(limitVal)
    .fetch(ServiceItemRow)

  var parts: seq[string] = @[]
  for r in rows:
    let payloadTag =
      if r.payload.isNone: "NULL"
      elif r.payload.get.len == 0: "EMPTY"
      else: "SOME(" & r.payload.get & ")"
    parts.add(r.label & ":" & payloadTag)
  parts.join("|")

proc {{project_snake}}_xact_stats*(): string {.volatile.} =
  "committed=" & $gCommittedOps & "|aborted=" & $gAbortedOps

proc {{project_snake}}_integrity_status*(): string {.stable.} =
  let intact = isCatalogIntact(PgxExtensionName, PgxCompiledFunctions)
  let violations = verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)
  let sha = loadedSoSha256(PgxExtensionName)
  var validHex64 = sha.len == 64
  for ch in sha:
    if ch notin {'0'..'9', 'a'..'f'}:
      validHex64 = false
  "intact=" & $intact & "|violations=" & $violations.len & "|sha64=" & $validHex64
