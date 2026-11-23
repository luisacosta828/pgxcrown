\set VERBOSITY terse

CREATE FUNCTION pg_temp.try_set_suset() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  SET ex11.strict_guard = off;
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_show_token() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SHOW ex11.audit_token';
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_read_token_udf() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM ex11_read_audit_token();
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_drop_protected() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'DROP TABLE ex11_protected_tbl';
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

-- 1. Preload & Secure GUCs (pg_settings excludes superuserOnly ex11.audit_token)
SHOW shared_preload_libraries;
SHOW ex11.max_rows;
SHOW ex11.strict_guard;
SHOW ex11.audit_token;
SELECT name, setting, context FROM pg_settings WHERE name LIKE 'ex11.%' ORDER BY name;

-- 2. SET LOCAL transactional rollback & RBAC with non-superuser role
BEGIN;
SET LOCAL ex11.max_rows = 12;
SELECT ex11_guc_status() AS status_in_tx;
ROLLBACK;
SELECT ex11_guc_status() AS status_after_rollback;

CREATE ROLE ex11_lowpriv LOGIN NOSUPERUSER;
SET ROLE ex11_lowpriv;
BEGIN;
SELECT ex11_set_max_rows_local('25') AS local_set_res;
SHOW ex11.max_rows;
COMMIT;
SELECT pg_temp.try_set_suset() AS suset_blocked,
       pg_temp.try_show_token() AS show_token_blocked,
       pg_temp.try_read_token_udf() AS udf_token_blocked;
RESET ROLE;
DROP ROLE ex11_lowpriv;

-- 3. Composable ExecutorEnd + ProcessUtility hooks coexisting with UDFs
SELECT ex11_reset_hooks() AS hooks_reset;
CREATE TABLE ex11_protected_tbl (id int PRIMARY KEY);
CREATE TABLE ex11_scratch_tbl (id int PRIMARY KEY);
CREATE TABLE ex11_tracked_tbl (id int PRIMARY KEY, label text NOT NULL);

INSERT INTO ex11_tracked_tbl VALUES (1, 'a'), (2, 'b');
SELECT id, label FROM ex11_tracked_tbl ORDER BY id;
UPDATE ex11_tracked_tbl SET label = 'b2' WHERE id = 2;

SELECT pg_temp.try_drop_protected() AS protected_drop_blocked;
DROP TABLE ex11_scratch_tbl;
SELECT ex11_hook_stats() AS hook_stats;

-- 4. Live catalog integrity attestation + SHA-256 verification + tamper detection
SELECT ex11_integrity_report() AS integrity_ok;
SELECT ex11_assert_intact() AS assert_ok;
BEGIN;
ALTER FUNCTION ex11_assert_intact() VOLATILE;
SELECT ex11_integrity_report() AS tampered_report;
ROLLBACK;
SELECT ex11_assert_intact() AS restored_after_rollback;
