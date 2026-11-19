# Shared Memory Preload Integration Suite

Verifies Pgxcrown static shared memory (`shared_preload_libraries`) across PostgreSQL 14–17:

- `installShmemHooks` (`shmem_request_hook` in PG 15–17, direct `_PG_init` request in PG 14, and chained `shmem_startup_hook`)
- `requestNamedTranche` & `getNamedTranche` (`LWLockPadded` array indexing)
- `initShmemStruct` (`AddinShmemInitLock` + POD guard + zero-init)
- Static `RegisterBackgroundWorker` (shmem-only daemon running concurrently with SQL backends)
- `pg_shmem_allocations` & `pg_stat_activity` inspection
