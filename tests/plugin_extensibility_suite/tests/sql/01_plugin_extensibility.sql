-- 1. Extension metadata & catalog objects created by pgxSql (pre + post)
SELECT extname, extversion, extrelocatable
FROM pg_extension
WHERE extname = 'plugin_extensibility_suite';

SELECT to_regclass('plugin_events') IS NOT NULL AS has_pre_events_table,
       to_regclass('plugin_audit_meta') IS NOT NULL AS has_pre_audit_table,
       to_regclass('idx_plugin_events_tag') IS NOT NULL AS has_post_idx,
       to_regclass('plugin_event_summary') IS NOT NULL AS has_post_view;

-- 2. Plugin contract functions and internal {.noSql.} types must NOT leak into SQL catalog
SELECT count(*) AS leaked_plugin_procs
FROM pg_proc
WHERE proname IN ('pgxsqltype', 'pgxtodatum', 'pgxfromdatum', 'toparam', 'toqueryparam');

SELECT count(*) AS leaked_nosql_types
FROM pg_type
WHERE typname IN ('BadgeValue', 'badgevalue');

-- 3. Automatic _PG_init without {.pgxInit.} executes registerPgxPluginInit hooks idempotently
SELECT pe_init_status() AS plugin_init_status;

-- 4. Mixin contract bridges for custom base type & Nim-only plugin struct
SELECT '  AlphaTag  '::"PluginTag" AS parsed_tag;
SELECT pe_describe_tag('BetaTag'::"PluginTag") AS described_tag;
SELECT pe_badge_roundtrip('gold', 99) AS badge_roundtrip;

-- 5. End-to-end table/view/index operations mixing pre-phase tables, Nim UDFs, and post-phase view
SELECT pe_seed_meta('schema_mode', 'v0.33_plugin') AS seeded_meta;
SELECT pe_record_event('ops'::"PluginTag", 10) AS ops_count_1;
SELECT pe_record_event('OPS'::"PluginTag", 25) AS ops_count_2;
SELECT pe_record_event('sec'::"PluginTag", 50) AS sec_count_1;

SELECT tag, total_events, total_score, tag_meta
FROM plugin_event_summary
ORDER BY tag;

SELECT k, v FROM plugin_audit_meta ORDER BY k;
