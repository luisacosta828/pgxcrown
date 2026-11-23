# Example 10: Shared Memory, LWLocks, and Dynamic Background Workers

This example demonstrates how to combine **PostgreSQL shared memory**, atomic and **`LWLock`** synchronization, and a **dynamic Background Worker** collaborating with live SQL sessions via `shared_preload_libraries`.

## What This Example Demonstrates

1. **Two complementary shared-memory styles**:
   - **Declarative `{.pgxShared.}`**: `var gPragmaTicks {.pgxShared("ex10_pragma_ticks").}: Atomic[int64]` reserves and initializes a cross-process shared atomic slot.
   - **Structured `initShmemStruct` + `{.pgxShmem.}`**: `Ex10SharedState` is sized with `requestShmemSpace[Ex10SharedState]` and atomically initialized under `AddinShmemInitLock` in `onEx10ShmemStartup`.
2. **`LWLock` synchronization (`getNamedTranche` + `withLock`)**:
   - Reserves a named tranche (`requestNamedTranche("ex10_tranche", 2)`) during startup and protects concurrent reads/writes between the background worker and SQL sessions (`lwExclusive` / `lwShared`).
3. **Dynamic Background Worker (`bgWorker` + `runWorkerLoop`)**:
   - Configures a worker with `library "10_shared_memory_and_bgworker"`, `entrypoint "ex10_metrics_worker"`, `database "postgres"`, and `restart 30`.
   - Launches it dynamically from SQL with `registerDynamicWorker`, tracks its lifecycle using `trackWorkerStarted`, `getWorkerStatusByName`, and `stopWorkerByName`, and shuts down cleanly on `SIGTERM`.
4. **`tests/preload` requirement**:
   - The `tests/preload` marker tells `pgxtool test` to configure `shared_preload_libraries = '10_shared_memory_and_bgworker'` and restart PostgreSQL before running `01_demo.sql`.

## File Layout

```text
10_shared_memory_and_bgworker/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── preload                 # Enables shared_preload_libraries in pgxtool test
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Building, Verifying, and Testing

```bash
pgxtool build-extension examples/10_shared_memory_and_bgworker
pgxtool verify examples/10_shared_memory_and_bgworker
pgxtool test examples/10_shared_memory_and_bgworker --pg 18
pgxtool test examples/10_shared_memory_and_bgworker --all
```

## Installing and Testing Manually in `psql`

```bash
pgxtool build-extension examples/10_shared_memory_and_bgworker
sudo ./examples/10_shared_memory_and_bgworker/src/install.sh
```

Enable `shared_preload_libraries` in PostgreSQL and restart the server before creating the extension:

```sql
ALTER SYSTEM SET shared_preload_libraries = '10_shared_memory_and_bgworker';
-- Restart PostgreSQL (e.g., pg_ctl restart)
```

```sql
CREATE EXTENSION "10_shared_memory_and_bgworker";

SELECT ex10_start_worker() > 0;
SELECT ex10_worker_status();
SELECT ex10_bump_shared(10);
SELECT ex10_lwlock_invariant_ok();
SELECT ex10_stop_worker();
SELECT ex10_worker_status();
```
