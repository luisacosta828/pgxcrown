# Example 03: `{.pure.}` Enums, Composite Types, and Arrays (`seq[T]` & `PgVector[T]`)

## What This Example Demonstrates

This example shows how to model structured domain types between Nim and PostgreSQL without writing manual SQL DDL:

- **`{.pure.}` enums**: `ex03_order_state` with explicit string labels (`'pending'`, `'confirmed'`, `'shipped'`) generates `CREATE TYPE "ex03_order_state" AS ENUM (...)`.
- **Composite types (`object`)**: `ex03_line_item` generates `CREATE TYPE "ex03_line_item" AS (...)` embedding the `ex03_order_state` enum, and passes cleanly as scalar arguments/results (`ex03_make_item`, `ex03_item_total_cents`), composite arrays (`seq[ex03_line_item]` -> `ex03_line_item[]`), and set-returning functions (`SETOF ex03_line_item` in `ex03_build_order`).
- **Native and zero-copy arrays**:
  - `seq[int32]` and `seq[string]` parameters (`int4[]`, `text[]`).
  - `PgVector[int32]` (`ex03_scale_vector`) for zero-copy read access over PostgreSQL arrays and direct `int4[]` return values.

## File Layout

```text
03_enums_composites_and_arrays/
├── pgxext.json                # Extension metadata (.control)
├── src/
│   └── main.nim               # Enum, composite object, and seq[T]/PgVector[T] UDFs
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # SQL tests for enum, composite, composite[], and arrays
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `starter-udf` template via `pgxtool new`

```bash
pgxtool new ./03_enums_composites_and_arrays --template starter-udf
```

Then define the `{.pure.}` `enum`, composite `object`, and `ex03_*` procedures in `src/main.nim`.

### Option B: Step by step manually

```bash
mkdir -p 03_enums_composites_and_arrays/src 03_enums_composites_and_arrays/tests/sql 03_enums_composites_and_arrays/tests/expected
```

1. Configure `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": true`.
2. Export `ex03_order_state* {.pure.}` and `ex03_line_item* = object` in `src/main.nim` together with their `*`-exported procedures.
3. Write `tests/sql/01_demo.sql` and `tests/expected/01_demo.out`.

## Building

```bash
pgxtool build-extension examples/03_enums_composites_and_arrays
```

## Verifying Security and Integrity

```bash
pgxtool verify examples/03_enums_composites_and_arrays
```

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/03_enums_composites_and_arrays --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/03_enums_composites_and_arrays --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/03_enums_composites_and_arrays/src/install.sh
```

In `psql`:

```sql
CREATE EXTENSION "03_enums_composites_and_arrays";

SELECT ex03_next_state('pending'::ex03_order_state);
SELECT (ex03_make_item('sku-101', 3, 450)).*;
SELECT ex03_sum_order_cents(ARRAY[
  ROW('SKU-A', 2, 500, 'pending')::ex03_line_item,
  ROW('SKU-B', 5, 300, 'confirmed')::ex03_line_item
]);
SELECT * FROM ex03_build_order(ARRAY['kbd-01', 'mouse-02'], ARRAY[2, 0], 1990);
SELECT ex03_scale_vector(ARRAY[2, -3, 5]::int4[], 10);

DROP EXTENSION "03_enums_composites_and_arrays";
```
