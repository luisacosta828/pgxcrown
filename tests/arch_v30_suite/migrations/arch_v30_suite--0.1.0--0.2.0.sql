ALTER TYPE "ArchStatus" ADD VALUE IF NOT EXISTS 'archived';

CREATE TYPE "ArchItem" AS (
  "id" int4,
  "label" Text,
  "status" "ArchStatus"
);

CREATE OR REPLACE FUNCTION v30_echo(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_echo_356672_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_echo(int8) returns int8 as
'arch_v30_suite', 'pgx_v30_echo_7ec6f3_int8'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_echo(float8) returns float8 as
'arch_v30_suite', 'pgx_v30_echo_286128_float8'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_echo(Text) returns Text as
'arch_v30_suite', 'pgx_v30_echo_41c057_text'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_echo(int4, int4) returns int4 as
'arch_v30_suite', 'pgx_v30_echo_2414ac_int4_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_describe("ArchItem") returns Text as
'arch_v30_suite', 'pgx_v30_describe_f57b91_architem'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_describe("ArchStatus") returns Text as
'arch_v30_suite', 'pgx_v30_describe_151cd6_archstatus'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_ping(Text) returns Text as
'arch_v30_suite', 'pgx_v30_ping_a567ee_text'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_scaled(int4, int4) returns int4 as
'arch_v30_suite', 'pgx_v30_scaled_2d608d_int4_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_stream_range(int8) returns SETOF int8 as
'arch_v30_suite', 'pgx_v30_stream_range_ad3b70_int8'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_stream_range(int8, int8) returns SETOF int8 as
'arch_v30_suite', 'pgx_v30_stream_range_a8b3ce_int8_int8'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_stream_texts(Text, int4) returns SETOF Text as
'arch_v30_suite', 'pgx_v30_stream_texts_dfc801_text_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_stream_items(int4) returns SETOF "ArchItem" as
'arch_v30_suite', 'pgx_v30_stream_items_4727b8_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_stream_error(int4) returns SETOF int4 as
'arch_v30_suite', 'pgx_v30_stream_error_55745b_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_seq_items(int4) returns SETOF Text as
'arch_v30_suite', 'pgx_v30_seq_items_12199b_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_privileged_vault_count() returns int8 as
'arch_v30_suite', 'pgx_v30_privileged_vault_count_25136a_void'
language c STRICT SECURITY DEFINER SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION v30_caller_vault_count() returns int8 as
'arch_v30_suite', 'pgx_v30_caller_vault_count_e6ef53_void'
language c STRICT SECURITY INVOKER SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION v30_safe_is_even(int4) returns boolean as
'arch_v30_suite', 'pgx_v30_safe_is_even_77ad3e_int4'
language c IMMUTABLE PARALLEL SAFE STRICT LEAKPROOF;

CREATE OR REPLACE FUNCTION v30_included_magic() returns int4 as
'arch_v30_suite', 'pgx_v30_included_magic_e61f42_void'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_init_sum() returns int4 as
'arch_v30_suite', 'pgx_v30_init_sum_f4a452_void'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_recurse_module(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_recurse_module_a53be7_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_recurse_nested(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_recurse_nested_5d8a30_int4'
language c STRICT;

CREATE OR REPLACE FUNCTION v30_udf_helper(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_udf_helper_5ff12f_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_udf_chain(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_udf_chain_3d4833_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_udf_text_and_composite(Text, "ArchStatus") returns Text as
'arch_v30_suite', 'pgx_v30_udf_text_and_composite_7edf6b_text_archstatus'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_udf_opt_echo(Text DEFAULT NULL) returns Text as
'arch_v30_suite', 'pgx_v30_udf_opt_echo_0c2252_text'
language c IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION v30_udf_opt_chain(Text DEFAULT NULL) returns Text as
'arch_v30_suite', 'pgx_v30_udf_opt_chain_cb3b0c_text'
language c IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION v30_udf_direct_recurse(int4) returns int4 as
'arch_v30_suite', 'pgx_v30_udf_direct_recurse_4315a4_int4'
language c IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION v30_udf_volatile_ping(Text) returns Text as
'arch_v30_suite', 'pgx_v30_udf_volatile_ping_e6ffd7_text'
language c STRICT;

CREATE OR REPLACE PROCEDURE v30_volatile_proc(int4) as
'arch_v30_suite', 'pgx_v30_volatile_proc_87f300_int4'
language c;

CREATE OR REPLACE PROCEDURE v30_explicit_void_proc(int4) as
'arch_v30_suite', 'pgx_v30_explicit_void_proc_4fc9eb_int4'
language c SECURITY DEFINER SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION v30_proc_counter() returns int4 as
'arch_v30_suite', 'pgx_v30_proc_counter_a1c883_void'
language c VOLATILE STRICT;

CREATE OR REPLACE FUNCTION v30_call_procs_dfc(int4, int4) returns int4 as
'arch_v30_suite', 'pgx_v30_call_procs_dfc_733b22_int4_int4'
language c VOLATILE STRICT;

CREATE OR REPLACE FUNCTION v30_syscache_probe() returns Text as
'arch_v30_suite', 'pgx_v30_syscache_probe_3e3bde_void'
language c STABLE STRICT;
