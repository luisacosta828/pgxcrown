-- 1. Extension metadata (.control override priority, trusted, relocatable)
SELECT extname, extversion, extrelocatable
FROM pg_extension
WHERE extname = 'arch_v30_suite';

SELECT version, relocatable, trusted, comment
FROM pg_available_extension_versions
WHERE name = 'arch_v30_suite'
ORDER BY version;

-- 2. Catalog verification: zero leaked private/noSql symbols & security metadata flags
SELECT count(*) AS leaked_private_types
FROM pg_type
WHERE typname IN ('PrivateCounter', 'PrivateExportedBuffer', 'NoSqlBuffer', 'InternalTypeOnly');

SELECT count(*) AS leaked_private_procs
FROM pg_proc
WHERE proname IN ('secretscale', 'secretScale', 'srcnosqladd', 'srcNoSqlAdd', 'modulerecursestep', 'innerstep');

SELECT proname, prosecdef, proleakproof, proconfig
FROM pg_proc
WHERE proname IN ('v30_privileged_vault_count', 'v30_caller_vault_count', 'v30_safe_is_even')
ORDER BY proname;

-- 3. Chained pgxInit across private/ and src/ submodules, include splicing, multi-arg IdentDefs
SELECT v30_init_sum() AS chained_init_sum;
SELECT v30_included_magic() AS included_magic;
SELECT v30_scaled(6, 7) AS scaled_42;
SELECT v30_pair_sum(10, 32) AS pair_sum_42;

-- 4. Function & composite/enum & iterator SQL overloads
SELECT v30_echo(42::int4) AS echo_i32;
SELECT v30_echo(5::int8) AS echo_i64;
SELECT v30_echo(3.5::float8) AS echo_f64;
SELECT v30_echo('nim'::text) AS echo_text;
SELECT v30_echo(19::int4, 23::int4) AS echo_pair;

SELECT v30_describe('active'::"ArchStatus") AS desc_status;
SELECT v30_describe(ROW(7, 'crown', 'archived')::"ArchItem") AS desc_item;

SELECT v30_ping() AS ping_void;
SELECT v30_ping('m2') AS ping_tagged;

SELECT array_agg(x ORDER BY x) AS range_5 FROM v30_stream_range(5) AS x;
SELECT array_agg(x ORDER BY x) AS range_10_12 FROM v30_stream_range(10, 12) AS x;

-- 5. Streaming O(1) iterators: 50k rows, early LIMIT 3 termination, Option NULLs, composite rows, mid-stream error, seq[string]
SELECT count(*) = 50000 AS count_ok,
       max(x) = 50000 AS max_ok,
       (SELECT sum(used_bytes) < 67108864 FROM pg_backend_memory_contexts) AS mem_bounded
FROM v30_stream_range(50000) AS x;

SELECT x FROM v30_stream_range(1000000) AS x LIMIT 3;

SELECT coalesce(t, '<NULL>') AS row_text FROM v30_stream_texts('row', 4) AS t;

SELECT id, label, status FROM v30_stream_items(3) ORDER BY id;

CREATE FUNCTION pg_temp.try_stream_error(fail_at int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  seen int := 0;
  v int;
BEGIN
  FOR v IN SELECT * FROM v30_stream_error(fail_at) LOOP
    seen := seen + 1;
  END LOOP;
  RETURN 'NO_ERROR:' || seen;
EXCEPTION WHEN OTHERS THEN
  RETURN 'rows=' || seen || ' msg=' || SQLERRM;
END $$;

CREATE FUNCTION pg_temp.try_call(sql_stmt text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  res text;
BEGIN
  EXECUTE sql_stmt INTO res;
  RETURN 'OK:' || coalesce(res, '');
EXCEPTION WHEN OTHERS THEN
  RETURN 'CAUGHT:' || SQLSTATE;
END $$;

SELECT pg_temp.try_stream_error(3) AS stream_error_result;

SELECT s FROM v30_seq_items(3) AS s;

-- 6. Automatic checkStackDepth() overflow guard (SQLSTATE 54001) & backend recovery
SELECT v30_recurse_module(5) AS module_ok_5;
SELECT v30_recurse_nested(5) AS nested_ok_5;

SELECT pg_temp.try_call('SELECT v30_recurse_module(50000)::text') AS module_stack_guard;
SELECT pg_temp.try_call('SELECT v30_recurse_nested(50000)::text') AS nested_stack_guard;

SELECT v30_recurse_module(6) AS recovered_module_6, v30_safe_is_even(42) AS even_42;

-- 9. Inter-UDF DirectFunctionCall (same-file, cross-module overloads, 0-arg, text/composite/enum, Option[T], self-recursion, volatile)
SELECT v30_udf_chain(5) AS udf_chain_4268;
SELECT v30_udf_text_and_composite('crown', 'active'::"ArchStatus") AS udf_txt_comp;
SELECT coalesce(v30_udf_opt_chain(NULL), '<NULL>') AS udf_opt_null,
       v30_udf_opt_chain('crown') AS udf_opt_val;
SELECT v30_udf_direct_recurse(5) AS udf_direct_rec_5;
SELECT pg_temp.try_call('SELECT v30_udf_direct_recurse(50000)::text') AS udf_direct_stack_guard;
SELECT v30_udf_direct_recurse(4) AS udf_direct_recovered_4;
SELECT v30_udf_volatile_ping('dfc') AS udf_volatile_ping;

-- 10. CREATE PROCEDURE (volatile + explicit : void) & SysCache / pg_proc / pg_type null-safe lookup
SELECT proname, prokind, prosecdef, proconfig
FROM pg_proc
WHERE proname IN ('v30_volatile_proc', 'v30_explicit_void_proc')
ORDER BY proname;

CALL v30_volatile_proc(5);
CALL v30_explicit_void_proc(3);
SELECT v30_proc_counter() AS proc_acc_35;
SELECT v30_call_procs_dfc(2, 4) AS proc_dfc_77;
SELECT v30_syscache_probe() AS syscache_probe;

-- 11. Converter hardening: float32 vec/DFC/composite, float64 precision, bool/int8, Datum(0), toPgVector ARC, QueryBuilder
SELECT v30_f32_double(1.25::float4) AS f32_double_25;
SELECT round(v30_float32_vec_sum(ARRAY[1.5::float4, 2.25::float4, -0.75::float4])::numeric, 2) AS f32_vec_sum_600;
SELECT v30_metrics_check(ROW(2.5::float4, true, 'K'::"char")::"ArchMetrics") AS metrics_check;
SELECT v30_converter_roundtrip() AS converter_roundtrip;
SELECT v30_qb_spi_live() AS qb_spi_live;

-- 7. SECURITY DEFINER vs SECURITY INVOKER + trusted non-superuser CREATE EXTENSION
CREATE TABLE public.arch_v30_priv_vault (id int);
INSERT INTO public.arch_v30_priv_vault VALUES (101), (202);
REVOKE ALL ON public.arch_v30_priv_vault FROM PUBLIC;

CREATE ROLE v30_unpriv LOGIN;
DO $$
BEGIN
  EXECUTE format('GRANT CREATE ON DATABASE %I TO v30_unpriv', current_database());
END $$;

SET ROLE v30_unpriv;
SELECT v30_privileged_vault_count() AS definer_vault_cnt;
SELECT pg_temp.try_call('SELECT v30_caller_vault_count()::text') AS invoker_vault_guard;
RESET ROLE;

DROP EXTENSION arch_v30_suite;
CREATE SCHEMA v30_unpriv_ns AUTHORIZATION v30_unpriv;
SET ROLE v30_unpriv;
CREATE EXTENSION arch_v30_suite SCHEMA v30_unpriv_ns;
SELECT v30_unpriv_ns.v30_ping('trusted') AS unpriv_trusted_ping;
DROP EXTENSION arch_v30_suite;
RESET ROLE;
DROP SCHEMA v30_unpriv_ns CASCADE;
DROP TABLE public.arch_v30_priv_vault;
DO $$
BEGIN
  EXECUTE format('REVOKE CREATE ON DATABASE %I FROM v30_unpriv', current_database());
END $$;
DROP ROLE v30_unpriv;

-- 8. Extension version upgrade path (0.1.0 -> 0.2.0 via ALTER EXTENSION UPDATE)
CREATE EXTENSION arch_v30_suite VERSION '0.1.0';
SELECT extversion AS before_ver, v30_ping() AS v01_ping, v30_pair_sum(20, 22) AS v01_sum
FROM pg_extension WHERE extname = 'arch_v30_suite';

ALTER EXTENSION arch_v30_suite UPDATE TO '0.2.0';
SELECT extversion AS after_ver FROM pg_extension WHERE extname = 'arch_v30_suite';
SELECT v30_describe(ROW(99, 'upgraded', 'archived')::"ArchItem") AS upgraded_item;
SELECT v30_echo('upgraded') AS upgraded_echo;
SELECT array_agg(x ORDER BY x) AS upgraded_stream FROM v30_stream_range(3) AS x;
SELECT v30_udf_chain(5) AS upgraded_udf_chain;
CALL v30_volatile_proc(5);
SELECT v30_proc_counter() AS upgraded_proc_82;
SELECT v30_syscache_probe() AS upgraded_syscache_probe;
SELECT round(v30_float32_vec_sum(ARRAY[1.5::float4, 2.25::float4, -0.75::float4])::numeric, 2) AS upgraded_f32_vec_sum;
SELECT v30_converter_roundtrip() AS upgraded_converter_roundtrip;
SELECT v30_qb_spi_live() AS upgraded_qb_spi_live;

DROP EXTENSION arch_v30_suite;
