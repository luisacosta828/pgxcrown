CREATE FUNCTION pg_temp.check_empty_label() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM {{project_snake}}_record('   ', 'ignored');
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN invalid_parameter_value THEN
  RETURN 'REJECTED_22023';
END $$;

SHOW {{guc_prefix}}.max_limit;
SHOW {{guc_prefix}}.strict_mode;
SELECT {{project_snake}}_policy_status() AS policy_default;
SELECT pg_temp.check_empty_label() AS strict_empty_check;

BEGIN;
SELECT {{project_snake}}_record('empty_item', '') > 0 AS empty_saved;
SELECT {{project_snake}}_record('val_item', 'hello') > 0 AS val_saved;
COMMIT;

BEGIN;
SELECT {{project_snake}}_record('rolled_back', NULL) > 0 AS abort_probe;
ROLLBACK;

SELECT {{project_snake}}_record('null_item', NULL) > 0 AS null_saved;

SELECT {{project_snake}}_xact_stats() AS xact_stats;
SELECT {{project_snake}}_fetch_summary() AS all_rows_summary;

BEGIN;
SET LOCAL {{guc_prefix}}.max_limit = 2;
SELECT {{project_snake}}_fetch_summary() AS limited_summary;
COMMIT;

SELECT {{project_snake}}_integrity_status() AS integrity_status;
