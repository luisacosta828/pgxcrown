import pgxcrown

pgxSql("{{project_snake}}_events_table", """
CREATE TABLE IF NOT EXISTS {{project_snake}}_events (
  id serial PRIMARY KEY,
  service_tag text NOT NULL,
  payload text NOT NULL
);
""", phase = "pre")

proc {{project_snake}}_tag*(): string {.immutable, parallelSafe.} =
  ## Returns the service_tag configured at scaffolding time.
  "{{service_tag}}"

proc {{project_snake}}_log*(payload: string): int64 {.volatile.} =
  ## Logs an event using Binary SPI v2 QueryBuilder tagged with service_tag.
  let t = table("{{project_snake}}_events")
  InsertInto(t, t.service_tag, t.payload)
    .Values("{{service_tag}}", payload)
    .Returning("id")
    .scalar(int64)
