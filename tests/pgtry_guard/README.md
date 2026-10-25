# 🛡️ PG_TRY Guard Regression Suite

Guards against a backend **segfault** when an error is raised after a successful
`pgTry` (any SPI call) inside the same UDF call.

**Root cause:** `pgx_call_guarded` (`src/pgxcrown/reports/reports.nim`) did
`return true` from inside `PG_TRY()`, skipping `PG_END_TRY()`. `PG_exception_stack`
was left pointing at a dead stack frame, so a later `ereport(ERROR)` in the same
call `siglongjmp`ed into garbage (`terminated by signal 11`).

## Run
```bash
pgxtool create-project pgtry_guard
cp tests/pgtry_guard/pgtry_guard_test.nim ~/<user>_pgxtool/pgtry_guard/src/main.nim
cp tests/pgtry_guard/sql/*.sql      ~/<user>_pgxtool/pgtry_guard/tests/sql/
cp tests/pgtry_guard/expected/*.out ~/<user>_pgxtool/pgtry_guard/tests/expected/
pgxtool test pgtry_guard --all
```
The expected output is identical on PostgreSQL 14–17. Errors are captured inside
`DO` blocks so the output is deterministic (no stdout/stderr interleaving).
