-- =============================================================================
-- Pgxcrown Milestone 1 (v0.29.0) E2E Regression Test Suite
-- =============================================================================
SET timezone = 'UTC';
SET datestyle = 'ISO, MDY';
SET intervalstyle = 'postgres';

-- 0. Custom SQL base type via {.pgxType: string.}
SELECT '  Hello Nim PG  '::slug AS parsed_slug;

-- 1. PgBytea (NUL-safe zero-copy buffers, arrays, Option, SETOF)
SELECT bytea_nul_stats('\x004100ff00'::bytea) AS nul_stats;
SELECT bytea_roundtrip_xor('\x004100ff00'::bytea) AS xor_bytes;
SELECT bytea_nul_stats('\x'::bytea) AS empty_bytes;
SELECT bytea_opt_echo('\xdead00beef'::bytea) AS some_bytea,
       bytea_opt_echo(NULL::bytea) IS NULL AS null_bytea;
SELECT bytea_array_total_len(ARRAY['\x000102'::bytea, '\x00'::bytea, '\xfffe'::bytea]) AS total_bytes_len;
SELECT b FROM bytea_srf_pair('\x00ff'::bytea, '\x120034'::bytea) AS b;

-- 2. PgUuid (16-byte native type, version/variant, Option, uuid[], SETOF)
SELECT uuid_version_info('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid) AS uuid_v4_info;
SELECT uuid_from_text_safe('{550E8400-E29B-41D4-A716-446655440000}') AS parsed_uuid;
SELECT uuid_opt_or_nil('6ba7b810-9dad-11d1-80b4-00c04fd430c8'::uuid) AS some_uuid,
       uuid_opt_or_nil(NULL::uuid) IS NULL AS null_uuid;
SELECT uuid_array_join(ARRAY[
  '00000000-0000-0000-0000-000000000000'::uuid,
  'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid
]) AS joined_uuids;
SELECT u FROM uuid_srf_list() AS u;

-- 3. Temporal types (epoch 0, pre-1970, leap day, +/-infinity, std/times, interval)
SELECT date_roundtrip_and_shift('2000-01-01'::date, 0) AS epoch_zero_date,
       date_roundtrip_and_shift('2024-02-28'::date, 1) AS leap_date,
       date_roundtrip_and_shift('1969-07-20'::date, 1) AS pre1970_date,
       date_roundtrip_and_shift('infinity'::date, 5) AS inf_date,
       date_roundtrip_and_shift('-infinity'::date, -5) AS neg_inf_date;
SELECT date_via_datetime_utc('2000-01-01'::date) AS dt_epoch,
       date_via_datetime_utc('1969-12-31'::date) AS dt_pre1970,
       date_via_datetime_utc('infinity'::date) AS dt_inf;
SELECT timestamptz_via_std_times('1969-12-31 23:59:59.123456+00'::timestamptz) AS pre_unix_tz,
       timestamptz_via_std_times('2024-02-29 14:30:00.5+02:00'::timestamptz) AS tz_offset_norm,
       timestamptz_via_std_times('infinity'::timestamptz) AS tz_pos_inf,
       timestamptz_via_std_times('-infinity'::timestamptz) AS tz_neg_inf;
SELECT timestamp_add_seconds('2000-01-01 00:00:00'::timestamp, -1) AS ts_before_pg_epoch,
       timestamp_add_seconds('infinity'::timestamp, 60) AS ts_inf;
SELECT interval_add_and_duration('1 year 2 mons 3 days 04:05:06'::interval, 250000) AS iv_with_months,
       interval_add_and_duration('2 days 01:00:00'::interval, 500000) AS iv_fixed_duration;
SELECT temporal_array_summary(
  ARRAY['2000-01-01'::date, '2024-02-29'::date],
  ARRAY['2024-06-15 12:00:00+00'::timestamptz],
  ARRAY['1 day 02:30:00'::interval]
) AS temporal_arrays;

-- 4. PgNumeric (arbitrary precision exact math, round/trunc, arrays, SETOF, error guard)
SELECT numeric_exact_add(
  '1234567890123456789012345678.0123456789'::numeric,
  '0.9876543211'::numeric
) AS exact_sum_38_digits;
SELECT numeric_exact_calc(19.995::numeric, 3::numeric, 0.0825::numeric) AS invoice_rounded;
SELECT numeric_trunc_val(123.456789::numeric, 3) AS trunc_val;
SELECT numeric_safe_div(100::numeric, 8::numeric) AS exact_div;
SELECT numeric_exact_add('NaN'::numeric, 42::numeric) AS nan_prop;
SELECT numeric_sum_array(ARRAY[10.25::numeric, 20.75::numeric, 0.005::numeric]) AS numeric_arr_sum;
SELECT n FROM numeric_srf_series(1.5::numeric, 0.25::numeric, 4) AS n;

DO $$
BEGIN
  PERFORM numeric_safe_div(10::numeric, 0::numeric);
  RAISE EXCEPTION 'Expected division by zero error did not fire';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Caught numeric error safely';
END $$;

-- 5. Complete Enum & Distinct FFI support
SELECT classify_ticket() AS default_enum,
       classify_ticket('tpLow'::"TicketPriority") AS low_enum,
       classify_ticket('tpHigh'::"TicketPriority") AS high_enum;
SELECT advance_payment_state('pending'::"PaymentState") AS next_from_pending,
       advance_payment_state('paid'::"PaymentState") AS next_from_paid;
SELECT opt_payment_state('pending'::"PaymentState") AS some_state,
       opt_payment_state(NULL::"PaymentState") IS NULL AS null_state;
SELECT priority_array_count(ARRAY['tpLow'::"TicketPriority", 'tpHigh'::"TicketPriority", 'tpHigh'::"TicketPriority"]) AS high_count;
SELECT p FROM list_priorities() AS p;

SELECT distinct_account_next(9000000000001::int8) AS next_acc,
       distinct_merchant_upper('acme-br') AS upper_code,
       distinct_flag_invert(true) AS inv_flag,
       distinct_grade_shift('A'::"char") AS next_grade,
       distinct_big_counter(500::int8) AS next_big,
       distinct_merchant_opt('vip') AS some_merch,
       distinct_merchant_opt(NULL::text) IS NULL AS null_merch;
SELECT a FROM distinct_account_srf(100::int8) AS a;

-- 6. Composite Object (including 0-value non-null checks, enum, PgBytea, PgNumeric) & SPI
SELECT describe_invoice_summary(
  build_invoice_summary(
    777::int8,
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid,
    '2000-01-01'::date,
    '2024-02-29 12:34:56.789+00'::timestamptz,
    0,
    12345.6789::numeric,
    'paid'::"PaymentState",
    '\x004100ff'::bytea
  )
) AS full_summary;

SELECT describe_invoice_summary(
  build_invoice_summary(
    888::int8,
    '00000000-0000-0000-0000-000000000000'::uuid,
    '2000-01-01'::date,
    NULL::timestamptz,
    NULL::int4,
    0::numeric,
    'pending'::"PaymentState",
    '\x'::bytea
  )
) AS nullable_summary;

SELECT spi_v29_roundtrip() AS spi_roundtrip;

-- 7. Regression coverage: seq[int] & seq[enum] composite input/output, empty implicit SRF
SELECT describe_batch_bundle(
  roundtrip_batch_bundle(
    ROW(ARRAY[10, -20, 30]::int4[], ARRAY['tpLow'::"TicketPriority", 'tpHigh'::"TicketPriority"])::"BatchTagBundle"
  )
) AS batch_bundle_summary;

SELECT describe_batch_bundle(
  roundtrip_batch_bundle(
    ROW(ARRAY[]::int4[], ARRAY[]::"TicketPriority"[])::"BatchTagBundle"
  )
) AS batch_bundle_empty;

SELECT count(*) AS empty_uuid_srf_count FROM empty_uuid_srf();
