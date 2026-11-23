\set VERBOSITY terse

-- 1. Verify pre-phase table, post-phase index/view, and zero leaked mixin procs
SELECT to_regclass('ex12_audit_log') IS NOT NULL AS has_pre_table,
       to_regclass('idx_ex12_audit_tag') IS NOT NULL AS has_post_idx,
       to_regclass('ex12_audit_summary') IS NOT NULL AS has_post_view;

SELECT count(*) AS leaked_mixin_procs
FROM pg_proc
WHERE proname IN ('pgxsqltype', 'pgxtodatum', 'pgxfromdatum', 'toparam', 'toqueryparam');

-- 2. Verify automatic _PG_init execution of registerPgxPluginInit (idempotent)
SELECT ex12_plugin_ready() AS plugin_initialized;

-- 3. Custom base type normalization & plugin_api mixin contract
SELECT '  SecOps  '::"Ex12AuditTag" AS parsed_tag;
SELECT ex12_describe_tag('SecOps'::"Ex12AuditTag") AS described_tag;

-- 4. Binary SPI v2 QueryBuilder combining Ex12AuditTag + Option[string] (EMPTY / NULL / SOME)
SELECT ex12_record_audit('secops'::"Ex12AuditTag", '') AS id_empty;
SELECT ex12_record_audit('SECOPS'::"Ex12AuditTag", NULL) AS id_null;
SELECT ex12_record_audit('  SecOps '::"Ex12AuditTag", 'login_ok') AS id_some;
SELECT ex12_record_audit('billing'::"Ex12AuditTag", 'invoice_1') AS id_billing;

SELECT ex12_fetch_audit('secops'::"Ex12AuditTag") AS secops_entries;

SELECT tag, entry_count, tag_meta
FROM ex12_audit_summary
ORDER BY tag;
