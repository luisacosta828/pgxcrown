-- Ejemplo 02: Parametros DEFAULT, Option[T], calledOnNullInput y Panic Shield
\set VERBOSITY terse

-- 1. Parametros DEFAULT
SELECT ex02_greet_default() AS greet_defaults,
       ex02_greet_default('PostgreSQL', 3) AS greet_custom;

-- 2. Option[T] como parametro y retorno (NULL seguro sin crashes)
SELECT ex02_safe_divide(42) IS NULL AS div_default_null,
       ex02_safe_divide(42, NULL) IS NULL AS div_explicit_null,
       ex02_safe_divide(42, 6) AS div_valid;

-- 3. {.calledOnNullInput.} (no STRICT: recibe NULL sin devolver NULL automaticamente)
SELECT proname, proisstrict
FROM pg_proc
WHERE proname IN ('ex02_coalesce_label', 'ex02_validate_port')
ORDER BY proname;

SELECT ex02_coalesce_label(NULL) AS null_uses_default_fallback,
       ex02_coalesce_label(NULL, 'guest') AS null_uses_custom_fallback,
       ex02_coalesce_label('  admin  ') AS trimmed_label;

-- 4. Wrapper determinista pg_temp para capturar SQLSTATE y mensajes de Panic Shield
CREATE FUNCTION pg_temp.ex02_try_call(sql_expr text)
RETURNS TABLE(outcome text, sqlstate_code text, msg text)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY EXECUTE 'SELECT ''OK''::text, ''00000''::text, (' || sql_expr || ')::text';
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT 'ERR'::text, SQLSTATE::text, SQLERRM::text;
END $$;

SELECT '1_value_error_port' AS test_case, outcome, sqlstate_code, msg
FROM pg_temp.ex02_try_call('ex02_validate_port(70000)')
UNION ALL
SELECT '2_pg_error_tag', outcome, sqlstate_code, msg
FROM pg_temp.ex02_try_call('ex02_require_tag(''   '')')
UNION ALL
SELECT '3_div_by_zero', outcome, sqlstate_code, msg
FROM pg_temp.ex02_try_call('ex02_safe_divide(10, 0)')
UNION ALL
SELECT '4_overflow_defect', outcome, sqlstate_code, msg
FROM pg_temp.ex02_try_call('ex02_checked_add(2147483647, 1)')
UNION ALL
SELECT '5_index_defect', outcome, sqlstate_code, msg
FROM pg_temp.ex02_try_call('ex02_pick_item(9)')
ORDER BY test_case;

-- 5. El backend sigue completamente operativo tras capturar errores y Defects
SELECT ex02_validate_port(5432) AS valid_port,
       ex02_require_tag('  prod  ') AS valid_tag,
       ex02_checked_add(20, 22) AS valid_sum,
       ex02_pick_item(1) AS valid_item;
