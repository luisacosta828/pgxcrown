\set VERBOSITY terse

SHOW shared_preload_libraries;

-- 1. Verify named shared memory allocations (initShmemStruct + {.pgxShared.})
SELECT name, allocated_size >= size AS valid_shmem
FROM pg_shmem_allocations
WHERE name IN ('ex10_shared_state', 'ex10_pragma_ticks')
ORDER BY name;

-- 2. Start dynamic background worker and wait deterministically (up to 5s) for ticks > 0
SELECT ex10_start_worker() > 0 AS worker_started;

DO $$
DECLARE
  i int;
BEGIN
  FOR i IN 1..50 LOOP
    EXIT WHEN ex10_worker_ticks() > 0
      AND ex10_pragma_ticks() > 0
      AND EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE backend_type = 'ex10_metrics_worker'
      );
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;

SELECT (ex10_worker_ticks() > 0 AND ex10_pragma_ticks() > 0) AS ticks_recorded;
SELECT ex10_worker_status() AS status_running;

-- 3. Update shared struct from SQL backend under LWLock while worker runs
SELECT ex10_bump_shared(10) AS sql_updates_10;
SELECT ex10_bump_shared(15) AS sql_updates_25;
SELECT ex10_lwlock_invariant_ok() AS lwlock_invariant_ok;

-- 4. Stop worker cleanly and confirm final persisted SQL updates
SELECT ex10_stop_worker() AS worker_stopped;
SELECT ex10_worker_status() AS status_stopped;
SELECT ex10_sql_updates() AS persisted_sql_updates;

-- 5. Confirm {.pgxShmem.} internal struct did not leak into pg_type
SELECT count(*) AS leaked_shmem_types
FROM pg_type
WHERE typname IN ('Ex10SharedState', 'ex10sharedstate');
