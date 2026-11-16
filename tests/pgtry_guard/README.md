# 🛡️ PG_TRY Guard Regression Suite

Guards against a backend **segfault** when an error is raised after a successful
`pgTry` (any SPI call) inside the same UDF call.

**Root cause:** `pgx_call_guarded` (`src/pgxcrown/reports/reports.nim`) did
`return true` from inside `PG_TRY()`, skipping `PG_END_TRY()`. `PG_exception_stack`
was left pointing at a dead stack frame, so a later `ereport(ERROR)` in the same
call `siglongjmp`ed into garbage (`terminated by signal 11`).

## Run
```bash
pgxtool test tests/pgtry_guard --all
```
Source lives in [`src/main.nim`](src/main.nim), with deterministic regression SQL in [`tests/sql/`](tests/sql) and golden outputs in [`tests/expected/`](tests/expected). Errors are captured inside
`DO` blocks so the output is deterministic across PostgreSQL 14–17 (no stdout/stderr interleaving).
