\set VERBOSITY terse

CREATE FUNCTION pg_temp.try_set_suset() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  SET v32interop.strict_audit = off;
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_show_secret() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SHOW v32interop.secret_token';
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_read_secret_udf() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM interop_secret_read();
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

CREATE FUNCTION pg_temp.try_drop_protected() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'DROP TABLE interop_protected_tbl';
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'BLOCKED_42501';
END $$;

-- 1. Preload, plugin_api init, and pgxSql pre/post DDL
SHOW shared_preload_libraries;
SELECT interop_status() AS initial_status;
SELECT indexname FROM pg_indexes WHERE tablename = 'interop_events' AND indexname = 'idx_interop_events_tag';

-- 2. Secure GUCs & RBAC
SHOW v32interop.batch_limit;
SHOW v32interop.strict_audit;
SHOW v32interop.secret_token;
SELECT name, setting, context FROM pg_settings WHERE name LIKE 'v32interop.%' ORDER BY name;

BEGIN;
SET LOCAL v32interop.batch_limit = 2;
SHOW v32interop.batch_limit;
ROLLBACK;
SHOW v32interop.batch_limit;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgx_interop_lowpriv') THEN
    CREATE ROLE pgx_interop_lowpriv LOGIN NOSUPERUSER;
  END IF;
END $$;
SET ROLE pgx_interop_lowpriv;
BEGIN;
SET LOCAL v32interop.batch_limit = 5;
SHOW v32interop.batch_limit;
COMMIT;
SELECT pg_temp.try_set_suset() AS lowpriv_suset_blocked,
       pg_temp.try_show_secret() AS lowpriv_show_blocked,
       pg_temp.try_read_secret_udf() AS lowpriv_udf_blocked;
RESET ROLE;
DROP ROLE IF EXISTS pgx_interop_lowpriv;

-- 3. XactCallback + SubXactCallback + Binary SPI v2 + Option[string] NULL vs ''
BEGIN;
SELECT interop_arm_subxact_probe() AS subxact_armed;
SELECT interop_record_event('  Alpha  '::InteropTag, '', 10) > 0 AS rec_empty;
SAVEPOINT sp1;
  INSERT INTO interop_events(tag, note, qty) VALUES ('alpha', 'aborted_sub', 99);
ROLLBACK TO SAVEPOINT sp1;
SAVEPOINT sp2;
  SELECT interop_record_event('alpha'::InteropTag, 'hello', 20) > 0 AS rec_val;
RELEASE SAVEPOINT sp2;
COMMIT;

SELECT interop_take_subxact_log() AS subxact_log;

BEGIN;
SELECT interop_record_event('alpha'::InteropTag, 'doomed', 30) > 0 AS rec_doomed;
ROLLBACK;

SELECT interop_record_event('alpha'::InteropTag, NULL, 40) > 0 AS rec_null;
SELECT interop_xact_counts() AS xact_counts;
SELECT interop_query_events('  ALPHA  '::InteropTag) AS spi_events;

BEGIN;
SET LOCAL v32interop.batch_limit = 2;
SELECT interop_query_events('alpha'::InteropTag) AS limited_events;
COMMIT;

-- 4. Composable ExecutorEnd + ProcessUtility_hook
SELECT interop_reset_hooks() AS hooks_reset;
CREATE TABLE interop_protected_tbl (id int PRIMARY KEY, v text);
CREATE TABLE interop_scratch_tbl (id int PRIMARY KEY);
CREATE TABLE interop_probe_tbl (id int PRIMARY KEY, v text);
INSERT INTO interop_probe_tbl VALUES (1, 'a'), (2, 'b');
SELECT id, v FROM interop_probe_tbl ORDER BY id;
SELECT pg_temp.try_drop_protected() AS protected_drop_blocked;
DROP TABLE interop_scratch_tbl;
SELECT interop_hook_stats() AS hook_stats;

-- 5. Live catalog integrity verification + transactional tamper check
SELECT interop_integrity_report() AS integrity_ok;
SELECT interop_assert_intact() AS assert_ok;
BEGIN;
ALTER FUNCTION interop_assert_intact() VOLATILE;
SELECT interop_integrity_report() AS tampered_report;
ROLLBACK;
SELECT interop_assert_intact() AS restored_after_rollback;
