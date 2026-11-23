\set VERBOSITY terse

SELECT ex09_reset() AS init_counts;

-- 1. Top-level COMMIT and ROLLBACK with one-shot callbacks and pgxWithLibcAlloc
BEGIN;
SELECT ex09_arm_tx('alpha') AS armed_commit_tx;
COMMIT;

BEGIN;
SELECT ex09_arm_tx('beta') AS armed_abort_tx;
ROLLBACK;

SELECT ex09_take_log(false) AS tx_log;
SELECT ex09_stats() AS stats_after_tx;

-- 2. Savepoint subtransactions (SAVEPOINT / ROLLBACK TO SAVEPOINT / RELEASE SAVEPOINT)
BEGIN;
SELECT ex09_arm_subxact() AS subxact_armed;
SAVEPOINT sp1;
  SAVEPOINT sp2;
  ROLLBACK TO SAVEPOINT sp2;
  RELEASE SAVEPOINT sp2;
COMMIT;

SELECT ex09_take_log(true) AS subxact_log;

-- 3. Anti-PANIC Shield in xeAbort: Nim exception becomes WARNING and remaining callbacks execute
BEGIN;
SELECT ex09_arm_abort_shield() AS shield_armed;
ROLLBACK;

SELECT ex09_take_log(false) AS shield_log;

-- 4. Controlled rejection during xePreCommit triggers clean ERROR + xeAbort cleanup
BEGIN;
SELECT ex09_arm_precommit_policy() AS policy_armed;
COMMIT;

SELECT ex09_take_log(true) AS precommit_abort_log;
SELECT ex09_stats() AS final_stats;
