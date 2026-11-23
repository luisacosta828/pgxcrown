CREATE FUNCTION pg_temp.try_assert_intact() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  res text;
BEGIN
  res := att_assert_intact();
  RETURN 'OK:' || res;
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'CAUGHT:' || SQLSTATE || ':' || (SQLERRM LIKE '%Catalog integrity violation%')::text;
END $$;

-- 1. Baseline intact extension verification
SELECT att_compiled_count() AS attested_fn_count;
SELECT att_is_intact() AS initial_intact;
SELECT att_check_catalog() AS initial_violations;
SELECT pg_temp.try_assert_intact() AS initial_assert;
SELECT att_loaded_so_info() AS loaded_so_info;

SELECT att_echo(21::int4) AS echo_i4,
       att_echo('crown'::text) AS echo_txt,
       att_sec_fn(5::int4) AS sec_fn_val;
CALL att_ping_proc(7);
SELECT att_proc_total() AS proc_total_7;

-- 2. Language / probin / prosrc tamper on overloaded att_echo(int4)
CREATE OR REPLACE FUNCTION att_echo(int4) RETURNS int4 LANGUAGE plpgsql AS $$
BEGIN
  RETURN 999;
END $$;

SELECT att_is_intact() AS after_plpgsql_intact;
SELECT att_check_catalog() AS after_plpgsql_violations;
SELECT pg_temp.try_assert_intact() AS after_plpgsql_assert;

-- 3. SECURITY DEFINER & search_path tamper on overloaded att_echo(text)
ALTER FUNCTION att_echo(text) SECURITY DEFINER SET search_path = pg_temp;
SELECT att_check_catalog() AS after_secdef_searchpath_violations;

-- 4. Volatility, SECURITY DEFINER, and search_path tamper on att_sec_fn(int4)
ALTER FUNCTION att_sec_fn(int4) VOLATILE SECURITY INVOKER RESET search_path;
SELECT att_check_catalog() AS after_secfn_tamper_violations;

-- 5. Procedure attribute tampering
ALTER PROCEDURE att_ping_proc(int4) SECURITY DEFINER SET search_path = pg_temp;
SELECT att_check_catalog() AS after_proc_tamper_violations;

-- 6. Detach function from extension -> EXTENSION_DETACHED
ALTER EXTENSION integrity_suite DROP FUNCTION att_echo(text);
SELECT att_check_catalog() AS after_detach_violations;

-- 7. Drop detached function -> FUNCTION_MISSING
DROP FUNCTION att_echo(text);
SELECT att_check_catalog() AS after_drop_violations;
SELECT pg_temp.try_assert_intact() AS final_assert;
