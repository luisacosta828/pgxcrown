# Example 09: Transaction Callbacks, Savepoints, and Anti-PANIC Shield

This example demonstrates `pgxcrown`'s transaction callback API (`v0.32`): `registerXactCallback` (`onPreCommit`, `onCommit`, `onAbort`), `registerSubXactCallback` for subtransactions (`SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`), memory lifetime isolation with `pgxWithLibcAlloc`, and the **Anti-PANIC Shield** during `xeAbort`.

## What This Example Demonstrates

1. **Transaction callbacks (`registerXactCallback`, `onCommit`, `onAbort`, `onPreCommit`)**:
   - Deterministic execution on `COMMIT`, `ROLLBACK`, and pre-commit validation in `xePreCommit` (where aborting with `raisePgError` is permitted).
   - One-shot registration (`once = true`) with automatic cleanup once triggered or aborted.
2. **Subtransactions (`registerSubXactCallback`)**:
   - Observes `sxeStartSub`, `sxePreCommitSub`, `sxeCommitSub`, and `sxeAbortSub` across `SAVEPOINT`, `ROLLBACK TO SAVEPOINT`, and `RELEASE SAVEPOINT`.
3. **Memory safety with `pgxWithLibcAlloc`**:
   - When an extension is compiled with `--wrap=malloc` under PostgreSQL, allocations inside a UDF default to the active statement/transaction `MemoryContext`.
   - `pgxWithLibcAlloc:` temporarily switches allocations to `libc malloc` for closures and log state (`gAuditLog`) that must outlive `TopTransactionContext` resets.
4. **Anti-PANIC Shield in `xeAbort` / `xeCommit`**:
   - In PostgreSQL, raising an `ERROR` (`ereport(ERROR)` / `longjmp`) during `XACT_EVENT_ABORT` or `XACT_EVENT_COMMIT` escalates to a `PANIC` and crashes the entire cluster.
   - `pgxcrown`'s Anti-PANIC Shield intercepts Nim exceptions and PostgreSQL errors in non-abortable phases, emits a controlled `WARNING`, and allows remaining callbacks to run without taking down the server.

## File Layout

```text
09_xact_callbacks_and_savepoints/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Building, Verifying, and Testing

```bash
pgxtool build-extension examples/09_xact_callbacks_and_savepoints
pgxtool verify examples/09_xact_callbacks_and_savepoints
pgxtool test examples/09_xact_callbacks_and_savepoints --pg 18
pgxtool test examples/09_xact_callbacks_and_savepoints --all
```

## Installing and Testing Manually in `psql`

```bash
pgxtool build-extension examples/09_xact_callbacks_and_savepoints
sudo ./examples/09_xact_callbacks_and_savepoints/src/install.sh
```

```sql
CREATE EXTENSION "09_xact_callbacks_and_savepoints";

SELECT ex09_reset();
BEGIN;
SELECT ex09_arm_tx('demo');
COMMIT;
SELECT ex09_take_log(false);

BEGIN;
SELECT ex09_arm_abort_shield();
ROLLBACK; -- Emits WARNING instead of PANIC
SELECT ex09_take_log(true);
```
