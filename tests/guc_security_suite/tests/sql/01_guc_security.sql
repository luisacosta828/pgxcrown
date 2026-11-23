\set VERBOSITY terse

SHOW shared_preload_libraries;

-- Initial defaults and direct .get() verification as superuser
SHOW gucsec.max_items;
SHOW gucsec.admin_flag;
SHOW gucsec.secret_key;
SHOW gucsec.mode;

SELECT guc_max_items_native() AS max_items_native,
       guc_admin_flag_native() AS admin_flag_native,
       guc_mode_native() AS mode_native,
       guc_secret_key_native() AS secret_key_native;

SELECT guc_get('gucsec.max_items') AS got_max,
       guc_get('gucsec.secret_key') AS got_secret,
       guc_get('gucsec.does_not_exist') IS NULL AS missing_is_null;

-- Verify superuserOnly GUC has GUC_NO_SHOW_ALL while regular custom GUCs appear in pg_settings
SELECT name, setting, context FROM pg_settings WHERE name LIKE 'gucsec.%' ORDER BY name;

-- Superuser enum & superuserOnly transactional update + rollback verification
BEGIN;
SELECT guc_set_local('gucsec.mode', 'fast') AS set_mode_res;
SELECT guc_set_local('gucsec.secret_key', 'rotated_secret') AS set_secret_res;
SELECT guc_mode_native() AS mode_in_tx,
       guc_secret_key_native() AS secret_in_tx,
       guc_get('gucsec.secret_key') AS secret_get_in_tx;
ROLLBACK;

SELECT guc_mode_native() AS mode_after_rollback,
       guc_secret_key_native() AS secret_after_rollback;

-- Protected core PostgreSQL GUCs, cross-prefix, and malformed names are blocked even for superuser
DO $$ BEGIN PERFORM guc_set_unscoped('log_statement', 'none');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'CORE_LOG_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_unscoped('search_path', 'pg_catalog');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'CORE_SEARCH_PATH_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_unscoped('pg.hack', '1');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'CORE_PG_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_local('otherext.flag', 'on');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'CROSS_PREFIX_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_local('gucsec.bad;sql', '1');
EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'BAD_SYNTAX_22023'; END $$;

-- Low-privilege role RBAC verification
DROP ROLE IF EXISTS pgx_lowpriv;
CREATE ROLE pgx_lowpriv LOGIN NOSUPERUSER;
SET ROLE pgx_lowpriv;

-- Low-priv CAN read and set gucsec.max_items within [1..1000]
SHOW gucsec.max_items;
SET gucsec.max_items = 42;
SHOW gucsec.max_items;
SELECT guc_max_items_native() AS lowpriv_max_native,
       guc_get('gucsec.max_items') AS lowpriv_max_get;

-- Low-priv CAN update via UDF and rollback SET LOCAL
BEGIN;
SET LOCAL gucsec.max_items = 99;
SELECT guc_max_items_native() AS inside_sql_local_tx;
ROLLBACK;
SELECT guc_max_items_native() AS after_sql_rollback;

BEGIN;
SELECT guc_set_local('gucsec.max_items', '88') AS udf_local_ok;
SELECT guc_max_items_native() AS inside_udf_local_tx;
ROLLBACK;
SELECT guc_max_items_native() AS after_udf_rollback;

-- Out-of-range value 2000 fails cleanly (22023)
DO $$ BEGIN SET gucsec.max_items = 2000;
EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'SQL_OOB_22023'; END $$;

DO $$ BEGIN PERFORM guc_set_local('gucsec.max_items', '2000');
EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'UDF_OOB_22023'; END $$;

-- Low-priv gets 42501 trying to set PGC_SUSET GUCs or core PG GUCs
DO $$ BEGIN SET gucsec.admin_flag = on;
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'SQL_ADMIN_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_local('gucsec.admin_flag', 'on');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'UDF_ADMIN_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_local('gucsec.mode', 'fast');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'UDF_MODE_42501'; END $$;

DO $$ BEGIN PERFORM guc_set_unscoped('log_statement', 'none');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'UDF_CORE_42501'; END $$;

-- Low-priv gets 42501 trying to inspect GUC_SUPERUSER_ONLY parameter via SHOW or getGuc
DO $$ BEGIN EXECUTE 'SHOW gucsec.secret_key';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'SHOW_SECRET_42501'; END $$;

DO $$ BEGIN PERFORM guc_get('gucsec.secret_key');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'GETGUC_SECRET_42501'; END $$;

DO $$ BEGIN PERFORM guc_secret_key_native();
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'NATIVE_SECRET_42501'; END $$;

-- Verify low-priv state remained intact after rejected operations
SELECT guc_max_items_native() AS final_max_items,
       guc_admin_flag_native() AS final_admin_flag,
       guc_mode_native() AS final_mode;

RESET ROLE;
DROP ROLE IF EXISTS pgx_lowpriv;
