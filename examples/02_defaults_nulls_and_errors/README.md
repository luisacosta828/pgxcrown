# Example 02: Default Parameters, NULL Safety, and Panic Shield

## What This Example Demonstrates

This example shows how to build resilient PostgreSQL UDFs that handle omitted arguments, `NULL` inputs/outputs, validation errors, and runtime defects without crashing the PostgreSQL backend process:

- **`DEFAULT` parameters**: `ex02_greet_default` and `ex02_safe_divide` translate Nim default parameter values directly into SQL `DEFAULT` clauses.
- **Bidirectional `Option[T]`**: `ex02_safe_divide` accepts `Option[int32]` and returns `Option[int32]`; returning `none(int32)` produces a real SQL `NULL` cleanly.
- **`{.calledOnNullInput.}`**: `ex02_coalesce_label` disables `STRICT` (`proisstrict = f`) so the Nim procedure still executes when SQL `NULL` is passed.
- **Controlled errors (`SQLSTATE`)**:
  - `raise newException(ValueError, ...)` in `ex02_validate_port` maps to SQLSTATE `22023` (`invalid_parameter_value`).
  - `raisePgError("22023", ...)` and `raisePgError("22012", ...)` raise native PostgreSQL errors with custom `hint` metadata and exact `SQLSTATE` codes.
- **Panic Shield (`Defect` -> `ereport(ERROR)`)**: `ex02_checked_add` (`OverflowDefect` -> `22003`) and `ex02_pick_item` (`IndexDefect` -> `2202E`) demonstrate that `pgxcrown` intercepts Nim defects before process abort and keeps the PostgreSQL session healthy.

## File Layout

```text
02_defaults_nulls_and_errors/
├── pgxext.json                # Extension metadata (.control)
├── src/
│   └── main.nim               # UDFs using defaults, Option[T], calledOnNullInput, and errors
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Deterministic tests using pg_temp wrappers and VERBOSITY terse
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `starter-udf` template via `pgxtool new`

```bash
pgxtool new ./02_defaults_nulls_and_errors --template starter-udf
```

Then import `std/options` in `src/main.nim` and define the `ex02_*` functions using `Option[T]`, `{.calledOnNullInput.}`, and `raisePgError`.

### Option B: Step by step manually

```bash
mkdir -p 02_defaults_nulls_and_errors/src 02_defaults_nulls_and_errors/tests/sql 02_defaults_nulls_and_errors/tests/expected
```

1. Configure `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": true`.
2. Implement `src/main.nim` with `std/options`, `{.calledOnNullInput.}`, `raise newException(ValueError, ...)`, and `raisePgError`.
3. Add `tests/sql/01_demo.sql` using `\set VERBOSITY terse` and `pg_temp.` exception-catching wrappers to verify each `SQLSTATE` deterministically.

## Building

```bash
pgxtool build-extension examples/02_defaults_nulls_and_errors
```

## Verifying Security and Integrity

```bash
pgxtool verify examples/02_defaults_nulls_and_errors
```

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/02_defaults_nulls_and_errors --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/02_defaults_nulls_and_errors --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/02_defaults_nulls_and_errors/src/install.sh
```

In `psql` (double-quoting the extension name because it begins with digits):

```sql
CREATE EXTENSION "02_defaults_nulls_and_errors";

SELECT ex02_greet_default();
SELECT ex02_safe_divide(42, NULL) IS NULL;
SELECT ex02_safe_divide(42, 6);
SELECT ex02_coalesce_label(NULL, 'guest');
SELECT ex02_validate_port(5432);

-- Trigger a controlled error or OverflowDefect (does not crash the session):
-- SELECT ex02_validate_port(70000);
-- SELECT ex02_checked_add(2147483647, 1);

DROP EXTENSION "02_defaults_nulls_and_errors";
```
