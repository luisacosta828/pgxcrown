# Example 04: Rich PostgreSQL Data Types (`JSONB`, `UUID`, `BYTEA`, `NUMERIC`, and Temporal)

## What This Example Demonstrates

This example shows how to operate directly on PostgreSQL's rich native data types without lossy text conversions or precision loss:

- **`JsonNode` (`jsonb`)**: reading, copying/mutating (`payload.copy()`), and returning `jsonb` documents safely (`ex04_json_tag`, `ex04_json_get`).
- **`PgUuid` (`uuid`)**: inspecting RFC 4122/9562 version and variant bits over native 16-byte UUIDs (`ex04_uuid_info`).
- **`PgBytea` (`bytea`)**: NUL-safe (`0x00`) zero-copy binary inspection and buffer construction (`ex04_bytea_stats`, `ex04_bytea_xor`).
- **`PgNumeric` (`numeric`)**: arbitrary-precision decimal arithmetic delegated to PostgreSQL's native numeric kernel (`ex04_numeric_total`).
- **Temporal types (`PgDate`, `PgTimestamp`, `PgTimestampTz`, `PgInterval`)**: seamless handling of PostgreSQL epochs, leap days, `infinity`/`-infinity`, and `std/times` conversions (`ex04_date_shift`, `ex04_ts_add_seconds`, `ex04_tstz_norm_utc`, `ex04_interval_add_us`).

## File Layout

```text
04_rich_datatypes_and_jsonb/
├── pgxext.json                # Extension metadata (.control)
├── src/
│   └── main.nim               # UDFs for JsonNode, PgUuid, PgBytea, PgNumeric, and temporals
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Deterministic tests pinning UTC, ISO/MDY, and intervalstyle
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `starter-udf` template via `pgxtool new`

```bash
pgxtool new ./04_rich_datatypes_and_jsonb --template starter-udf
```

Then import `std/[json, options, strutils]` and implement the `ex04_*` functions in `src/main.nim`.

### Option B: Step by step manually

```bash
mkdir -p 04_rich_datatypes_and_jsonb/src 04_rich_datatypes_and_jsonb/tests/sql 04_rich_datatypes_and_jsonb/tests/expected
```

1. Configure `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": true`.
2. Implement the UDFs in `src/main.nim` using `JsonNode`, `PgUuid`, `PgBytea`, `PgNumeric`, `PgDate`, `PgTimestamp`, `PgTimestampTz`, and `PgInterval`.
3. Pin `SET timezone = 'UTC'; SET datestyle = 'ISO, MDY'; SET intervalstyle = 'postgres';` at the top of `tests/sql/01_demo.sql` to guarantee identical formatting across PostgreSQL 14–18.

## Building

```bash
pgxtool build-extension examples/04_rich_datatypes_and_jsonb
```

## Verifying Security and Integrity

```bash
pgxtool verify examples/04_rich_datatypes_and_jsonb
```

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/04_rich_datatypes_and_jsonb --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/04_rich_datatypes_and_jsonb --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/04_rich_datatypes_and_jsonb/src/install.sh
```

In `psql`:

```sql
CREATE EXTENSION "04_rich_datatypes_and_jsonb";

SET timezone = 'UTC';
SELECT ex04_json_tag('{"app": "pgxcrown"}'::jsonb, 'audited');
SELECT ex04_uuid_info('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid);
SELECT ex04_bytea_stats('\x004100ff00'::bytea);
SELECT ex04_numeric_total(19.995::numeric, 3::numeric, 0.0825::numeric);
SELECT ex04_tstz_norm_utc('2024-02-29 14:30:00.5+02:00'::timestamptz);

DROP EXTENSION "04_rich_datatypes_and_jsonb";
```
