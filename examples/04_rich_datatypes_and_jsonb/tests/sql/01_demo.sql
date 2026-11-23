-- Ejemplo 04: Tipos ricos de PostgreSQL (JSONB, UUID, BYTEA, NUMERIC y temporales)
SET timezone = 'UTC';
SET datestyle = 'ISO, MDY';
SET intervalstyle = 'postgres';

-- 1. JsonNode -> jsonb
SELECT ex04_json_tag('{"app": "pgxcrown", "tier": "core"}'::jsonb) AS tagged_default,
       ex04_json_tag('{"app": "pgxcrown"}'::jsonb, 'audited') AS tagged_custom;

SELECT ex04_json_get('{"name": "nim", "lang": "systems"}'::jsonb, 'name') AS present_key,
       ex04_json_get('{"name": "nim"}'::jsonb, 'missing') IS NULL AS missing_is_null;

-- 2. PgUuid (16 bytes nativos)
SELECT ex04_uuid_info('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid) AS uuid_v4,
       ex04_uuid_info('018f4230-1a2b-7c3d-8000-112233445566'::uuid) AS uuid_v7;

-- 3. PgBytea (buffer binario seguro con bytes NUL)
SELECT ex04_bytea_stats('\x004100ff00'::bytea) AS bytea_stats,
       ex04_bytea_xor('\x004100ff00'::bytea, 255) AS bytea_xored;

-- 4. PgNumeric (aritmetica decimal de precision arbitraria)
SELECT ex04_numeric_total(19.995::numeric, 3::numeric, 0.0825::numeric) AS invoice_total,
       ex04_numeric_total(12345678901234567890.12::numeric, 2::numeric, 0.10::numeric) AS big_invoice_total;

-- 5. Tipos temporales deterministas en UTC / ISO / postgres
SELECT ex04_date_shift('2024-02-28'::date, 1) AS leap_day,
       ex04_date_shift('1969-12-31'::date, 1) AS unix_epoch,
       ex04_date_shift('infinity'::date, 5) AS inf_date;

SELECT ex04_ts_add_seconds('2000-01-01 00:00:00'::timestamp, -1) AS before_pg_epoch,
       ex04_tstz_norm_utc('2024-02-29 14:30:00.5+02:00'::timestamptz) AS utc_normalized,
       ex04_interval_add_us('1 year 2 mons 3 days 04:05:06'::interval, 250000) AS shifted_interval;
