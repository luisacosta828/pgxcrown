# Example 05: Custom SQL Base Type (`{.pgxType: string.}`), B-tree Operators, and Index

## What This Example Demonstrates

This example builds a custom PostgreSQL base data type (`ex05_iban`) end to end with strict Nim input validation and full B-tree indexing support:

- **Declarative base type (`{.pgxType: string.}`)**: `ex05_iban` automatically emits the shell type, `INPUT`/`OUTPUT` functions (`parse_ex05_iban`, `format_ex05_iban`), and `CREATE TYPE "ex05_iban" (... LIKE = Text)`.
- **Parser validation (`22023`)**: `parse_ex05_iban` normalizes whitespace and casing, checks IBAN length/character structure, and validates the ISO 7064 Mod-97-10 check digits. Invalid values raise `ValueError` (`SQLSTATE 22023`).
- **B-tree operators and index via `pgxSql(..., phase = "post")`**:
  - Defines comparison operators `<`, `<=`, `=`, `<>`, `>=`, `>` backed by Nim functions and the three-way comparator `ex05_iban_cmp`.
  - Registers `CREATE OPERATOR CLASS ex05_iban_ops DEFAULT FOR TYPE ex05_iban USING btree`.
  - Creates the real table `ex05_ledger` and B-tree index `idx_ex05_ledger_iban`, enabling native `WHERE` filtering and `ORDER BY` sorting.
- **Privilege safety (`"trusted": false`)**: creating operators and operator classes requires superuser privileges in PostgreSQL, so `pgxext.json` explicitly sets `"trusted": false` and `"relocatable": true` without hardcoding schema names.

## File Layout

```text
05_custom_base_type/
├── pgxext.json                # Extension metadata (.control) with trusted: false
├── src/
│   └── main.nim               # ex05_iban type, Mod-97 parser, operators, and pgxSql B-tree DDL
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Validation, operators, WHERE/ORDER BY, and B-tree index checks
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `base-type` template via `pgxtool new`

```bash
pgxtool new ./05_custom_base_type --template base-type --var type_name=ex05_iban
```

Then set `"trusted": false` in `pgxext.json` and add the comparison functions, B-tree operator class, and `ex05_ledger` table DDL inside `pgxSql(..., phase = "post")` in `src/main.nim`.

### Option B: Step by step manually

```bash
mkdir -p 05_custom_base_type/src 05_custom_base_type/tests/sql 05_custom_base_type/tests/expected
```

1. Configure `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": false`.
2. Define `ex05_iban* {.pgxType: string.} = distinct string`, `parse_ex05_iban` (`{.pgxInput.}`), `format_ex05_iban` (`{.pgxOutput.}`), the comparison functions, and the `pgxSql(..., phase = "post")` DDL block.
3. Add regression tests in `tests/sql/01_demo.sql` and `tests/expected/01_demo.out`.

## Building

```bash
pgxtool build-extension examples/05_custom_base_type
```

## Verifying Security and Integrity

```bash
pgxtool verify examples/05_custom_base_type
```

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/05_custom_base_type --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/05_custom_base_type --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/05_custom_base_type/src/install.sh
```

Connect as a superuser in `psql` (required because `"trusted": false`):

```sql
CREATE EXTENSION "05_custom_base_type";

SELECT '  de89 3704 0044 0532 0130 00  '::ex05_iban;
SELECT ex05_iban_masked('es91 2100 0418 4502 0005 1332'::ex05_iban);

INSERT INTO ex05_ledger (id, iban, holder, balance_cents) VALUES
  (1, 'de89 3704 0044 0532 0130 00', 'Berlin Ops', 125000),
  (2, 'es91 2100 0418 4502 0005 1332', 'Madrid Retail', 280000);

SELECT id, iban, holder FROM ex05_ledger ORDER BY iban;

DROP EXTENSION "05_custom_base_type";
```
