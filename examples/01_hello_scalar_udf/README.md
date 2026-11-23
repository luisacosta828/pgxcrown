# Example 01: Basic Scalar UDFs, Volatility, and Parallel Safety

## What This Example Demonstrates

This first example shows how to write PostgreSQL scalar user-defined functions (UDFs) in Nim using `pgxcrown`:

- **Automatic SQL export**: every `proc` exported with `*` generates a `CREATE OR REPLACE FUNCTION` DDL statement along with its PostgreSQL V1 C interface wrapper.
- **Volatility attributes**:
  - `{.immutable.}` (`ex01_greet`, `ex01_add`, `ex01_slugify`): guarantees no side effects (`noSideEffect`, `provolatile = 'i'`).
  - `{.stable.}` (`ex01_discount`): permits consistent reads within a single statement (`provolatile = 's'`).
  - `{.volatile.}` (`ex01_next_seq`): maintains mutable per-session backend state (`provolatile = 'v'`).
- **Parallel query safety**: `{.parallelSafe.}` marks pure functions as `PARALLEL SAFE` (`proparallel = 's'`) so the PostgreSQL planner can execute them inside parallel workers.
- **Catalog verification**: the regression test queries `pg_proc` to verify `provolatile`, `proparallel`, and `proisstrict`.

## File Layout

```text
01_hello_scalar_udf/
├── pgxext.json                # Extension metadata (.control)
├── src/
│   └── main.nim               # Nim implementation of the scalar UDFs
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Demo and regression SQL script
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `starter-udf` template via `pgxtool new`

```bash
pgxtool new ./01_hello_scalar_udf --template starter-udf
```

Then replace the generated `pgxext.json`, `src/main.nim`, and `tests/sql/01_demo.sql` with the `ex01_*` functions from this example.

### Option B: Step by step manually

```bash
mkdir -p 01_hello_scalar_udf/src 01_hello_scalar_udf/tests/sql 01_hello_scalar_udf/tests/expected
```

1. Create `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": true`.
2. Write `src/main.nim` importing `pgxcrown` and exporting (`*`) each `proc` decorated with `{.immutable, parallelSafe.}`, `{.stable.}`, and `{.volatile.}`.
3. Add the SQL queries to `tests/sql/01_demo.sql` and the expected output to `tests/expected/01_demo.out`.

## Building

```bash
pgxtool build-extension examples/01_hello_scalar_udf
```

This compiles the shared library (`src/01_hello_scalar_udf.so`), generates the `.control` file, emits the installation SQL script, and writes the `.integrity.json` manifest.

## Verifying Security and Integrity

```bash
pgxtool verify examples/01_hello_scalar_udf
```

Runs the ELF prohibited-symbol audit, shared library dependency check, and SHA-256 artifact integrity verification.

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/01_hello_scalar_udf --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/01_hello_scalar_udf --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/01_hello_scalar_udf/src/install.sh
```

Then open `psql` and **double-quote the extension name** because it starts with digits:

```sql
CREATE EXTENSION "01_hello_scalar_udf";

SELECT ex01_greet('PostgreSQL');
SELECT ex01_add(19, 23);
SELECT ex01_slugify('  Hello   Pgxcrown   2026  ');
SELECT ex01_discount(120.0, 25.0);
SELECT ex01_next_seq(), ex01_next_seq();

SELECT proname, provolatile, proparallel, proisstrict
FROM pg_proc
WHERE proname IN ('ex01_greet', 'ex01_add', 'ex01_slugify', 'ex01_discount', 'ex01_next_seq')
ORDER BY proname;

DROP EXTENSION "01_hello_scalar_udf";
```
