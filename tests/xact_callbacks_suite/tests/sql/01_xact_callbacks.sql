-- PostgreSQL Xact & SubXact Callbacks E2E Regression Suite
SELECT xact_reset_all() AS init_counts;

-- 1. COMMIT & ROLLBACK lifecycle with raw + convenience callbacks
BEGIN;
SELECT xact_arm_basic() AS armed_cnt;
SELECT 1 AS work;
COMMIT;

BEGIN;
SELECT 2 AS doomed_work;
ROLLBACK;

SELECT xact_take_log(true) AS commit_and_rollback_log;
SELECT xact_counts() AS counts_after_disarm;

-- 2. SAVEPOINT / ROLLBACK TO SAVEPOINT / RELEASE SAVEPOINT / COMMIT subxact lifecycle
BEGIN;
SELECT xact_arm_subxact() AS sub_armed_cnt;
SAVEPOINT sp1;
  SAVEPOINT sp2;
  ROLLBACK TO SAVEPOINT sp2;
  RELEASE SAVEPOINT sp2;
COMMIT;
SELECT xact_take_log(true) AS subxact_commit_log;

-- Subxact abort via top-level ROLLBACK
BEGIN;
SELECT xact_arm_subxact() AS sub_armed_abort_cnt;
SAVEPOINT sp_outer;
ROLLBACK;
SELECT xact_take_log(true) AS subxact_rollback_log;

-- 3. Anti-PANIC shield: Nim error in xeAbort must emit WARNING and NOT crash server
BEGIN;
SELECT xact_arm_panic_shield('abort_exc') AS armed_abort_exc;
ROLLBACK;
SELECT xact_take_log(true) AS abort_exc_log;

-- Anti-PANIC shield: direct C pgError (ereport ERROR) in xeAbort must emit WARNING
BEGIN;
SELECT xact_arm_panic_shield('abort_pgerror') AS armed_abort_pgerr;
ROLLBACK;
SELECT xact_take_log(true) AS abort_pgerr_log;

-- Anti-PANIC shield: Nim Defect in xeCommit must emit WARNING and NOT crash server
BEGIN;
SELECT xact_arm_panic_shield('commit_defect') AS armed_commit_def;
COMMIT;
SELECT xact_take_log(true) AS commit_def_log;

-- Anti-PANIC shield: errors in sxeAbortSub and sxeCommitSub emit WARNING
BEGIN;
SELECT xact_arm_panic_shield('subxact_exc') AS armed_sub_exc;
SAVEPOINT sp_a;
ROLLBACK TO SAVEPOINT sp_a;
RELEASE SAVEPOINT sp_a;
COMMIT;
SELECT xact_take_log(true) AS subxact_exc_log;

-- 4. Pre-commit failures must abort transaction cleanly with controlled ERROR
BEGIN;
SELECT xact_arm_precommit_fail('pgerror') AS armed_precommit_pgerr;
COMMIT;
SELECT xact_take_log(true) AS precommit_pgerr_log;

BEGIN;
SELECT xact_arm_precommit_fail('defect') AS armed_precommit_def;
COMMIT;
SELECT xact_take_log(true) AS precommit_def_log;

BEGIN;
SELECT xact_arm_precommit_fail('sub') AS armed_sub_precommit;
SAVEPOINT sp_fail;
RELEASE SAVEPOINT sp_fail;
ROLLBACK;
SELECT xact_take_log(true) AS sub_precommit_log;

-- 5. Unregistering, one-shot (once = true), self-unregister during dispatch, and pgxWithLibcAlloc closure capture
BEGIN;
SELECT xact_setup_lifecycle_test('alpha') AS setup_res;
SELECT 'between_stmts_1' AS step1;
SELECT 'between_stmts_2' AS step2;
COMMIT;

BEGIN;
SELECT xact_take_log(false) AS first_commit_log;
COMMIT;

SELECT xact_unregister_saved() AS unreg_res;
SELECT xact_take_log(false) AS second_commit_log;

BEGIN;
COMMIT;
SELECT xact_take_log(true) AS after_unreg_log;

SELECT 'server_alive_after_all_xact_tests' AS final_status;
