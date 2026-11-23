# Plugin & Extensibility E2E Test Suite (v0.33.0)

Verifies end-to-end across PostgreSQL 14–18:
- `pgxSql` `"pre"` and `"post"` SQL DDL blocks across local plugin submodules and `main.nim`
- Automatic `_PG_init` invoking `runPgxPluginInits()` cleanly without any `{.pgxInit.}` in `main.nim`
- `mixin` plugin contract (`pgxSqlType`, `pgxToDatum`, `pgxFromDatum`, `toParam`) and typed generic bridges
- SQL view/index referencing custom base types and extension UDFs alongside SPI DML
