-- Ejemplo 06: Iteradores SRF en streaming O(1), sobrecarga, NULLs, compuestos y limpieza segura
\set VERBOSITY terse

-- 1. Iterador SETOF int64 sobrecargado (1 y 2 argumentos)
SELECT array_agg(x ORDER BY x) AS range_1_to_5 FROM ex06_stream_range(5) AS x;
SELECT array_agg(x ORDER BY x) AS range_10_to_14 FROM ex06_stream_range(10, 14) AS x;

-- 2. Streaming O(1) con 50,000 filas y terminacion temprana via LIMIT 3
SELECT count(*) = 50000 AS streamed_50k_ok,
       sum(x) = 1250025000 AS sum_50k_ok
FROM ex06_stream_range(50000) AS x;

SELECT x FROM ex06_stream_range(1000000) AS x LIMIT 3;

-- 3. Iterador Option[string] emitiendo NULL reales de SQL
SELECT row_val IS NULL AS is_sql_null,
       coalesce(row_val, '<NULL>') AS display_val
FROM ex06_stream_nullable('row', 4) AS row_val;

-- 4. Iterador que emite registros compuestos SETOF ex06_event_row
SELECT seq_no, label, is_even
FROM ex06_stream_events(4)
ORDER BY seq_no;

-- 5. Limpieza segura ante fin normal, LIMIT temprano y error en mitad del stream
SELECT array_agg(v ORDER BY v) AS full_guarded_run
FROM ex06_stream_guarded(4, 0) AS v;
SELECT ex06_cleanup_count() AS cleanup_after_full;

SELECT v AS early_limit_row
FROM ex06_stream_guarded(1000, 0) AS v
LIMIT 2;
SELECT ex06_cleanup_count() AS cleanup_after_limit;

CREATE FUNCTION pg_temp.ex06_try_stream_error(fail_at int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  seen int := 0;
  v int;
BEGIN
  FOR v IN SELECT * FROM ex06_stream_guarded(20, fail_at) LOOP
    seen := seen + 1;
  END LOOP;
  RETURN 'UNEXPECTED_NO_ERROR:' || seen;
EXCEPTION WHEN OTHERS THEN
  RETURN 'rows=' || seen || '|sqlstate=' || SQLSTATE || '|msg=' || SQLERRM;
END $$;

SELECT pg_temp.ex06_try_stream_error(4) AS mid_stream_abort;
SELECT ex06_cleanup_count() AS cleanup_after_error;

-- 6. Verificar que el stream sigue funcionando normalmente tras el error
SELECT array_agg(v ORDER BY v) AS recovered_stream
FROM ex06_stream_guarded(3, 0) AS v;
