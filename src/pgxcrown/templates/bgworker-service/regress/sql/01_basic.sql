SELECT start_{{project_snake}}_worker() > 0 AS worker_started;
DO $$
DECLARE
  i int;
BEGIN
  FOR i IN 1..50 LOOP
    EXIT WHEN {{project_snake}}_ticks() > 0
      AND EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE backend_type = '{{project_name}}'
      );
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;
SELECT ({{project_snake}}_ticks() > 0) AS ticks_recorded;
SELECT {{project_snake}}_worker_status() AS status_running;
SELECT stop_{{project_snake}}_worker() AS worker_stopped;
SELECT {{project_snake}}_worker_status() AS status_stopped;
