\set VERBOSITY terse
SHOW shared_preload_libraries;
SELECT hooks_installed() AS hooks_active;
SELECT hook_udf_echo('coexists') AS udf_ok;
SELECT reset_hook_counters() AS reset_status;

CREATE TABLE protected_audit_tbl (id int PRIMARY KEY, label text NOT NULL);
CREATE TABLE temp_scratch_tbl (id int);
CREATE TABLE temp_batch_tbl (id int);

INSERT INTO protected_audit_tbl VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');
SELECT id, label FROM protected_audit_tbl ORDER BY id;
UPDATE protected_audit_tbl SET label = 'beta_v2' WHERE id = 2;
DELETE FROM protected_audit_tbl WHERE id = 1;

SELECT hook_stats() AS stats_after_dml;
SELECT hook_rows_processed() AS rows_including_prev_stats_select;

-- Normal DROP TABLE of non-protected table is allowed
DROP TABLE temp_scratch_tbl;

-- Direct DROP TABLE of protected table must fail with SQLSTATE 42501
DROP TABLE protected_audit_tbl;
DROP TABLE public.protected_audit_tbl;
DROP TABLE temp_batch_tbl, protected_audit_tbl;

-- PL/pgSQL EXCEPTION handler confirms exact SQLSTATE 42501 (insufficient_privilege)
DO $$
BEGIN
  EXECUTE 'DROP TABLE protected_audit_tbl';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'ERR_42501';
END $$;

-- Verify protected table and temp_batch_tbl are intact and counters tracked blocked drops
SELECT count(*) AS protected_rows_intact FROM protected_audit_tbl;
DROP TABLE temp_batch_tbl;
SELECT hook_stats() AS final_stats;
