SELECT start_{{project_snake}}_worker() > 0 AS worker_started;
DO $$
DECLARE
  i int;
BEGIN
  FOR i IN 1..40 LOOP
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE backend_type = '{{project_name}}'
    );
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT {{project_snake}}_worker_status() AS status_running;
SELECT stop_{{project_snake}}_worker() AS worker_stopped;
SELECT {{project_snake}}_worker_status() AS status_stopped;
