# Example 07: Multi-Module Extension, SQL Procedures, and Schema Snapshots/Migrations

This example demonstrates how to structure a production PostgreSQL extension across **multiple Nim modules**, expose SQL procedures (`CALL`), apply privilege hardening (`SECURITY DEFINER`, `search_path`, `LEAKPROOF`), and manage version lifecycles (`0.1.0` → `0.2.0`) using automatic schema snapshots and incremental migrations.

## What This Example Demonstrates

1. **Multi-module architecture** (`src/main.nim` + `src/billing_ops.nim`):
   - `pgxcrown` topologically walks imported local modules and generates a single `.so` shared library and a single unified SQL installation script.
   - Both modules define `{.pgxInit.}`, executing deterministically inside `_PG_init` (imported submodules first, `main.nim` afterward).
   - Internal helper functions marked with `{.noSql.}` (`computeCentsInternal`) are excluded from the PostgreSQL `pg_proc` catalog.
2. **Declarative metadata (`pgxext.json` + `pgxExtension:`)**:
   - `pgxext.json` supplies base configuration (`"version": "0.1.0"`, `"relocatable"`, `"trusted"`).
   - The `pgxExtension:` block in `src/main.nim` takes precedence and overrides fields in the generated `.control` file (for example, `trusted = true`).
3. **SQL Procedures (`PROCEDURE`)**:
   - Any exported Nim `proc` without a return type (or returning `: void`) compiles to `CREATE OR REPLACE PROCEDURE ... LANGUAGE c`, invocable via `CALL ex07_post_charge(1500);`.
4. **Function privilege hardening**:
   - `{.securityDefiner, searchPath: "public, pg_catalog".}` sets `SECURITY DEFINER` and `SET search_path = public, pg_catalog` to prevent schema-shadowing attacks.
   - `{.securityInvoker.}` preserves the caller's privileges.
   - `{.leakproof.}` marks pure predicates (`ex07_is_valid_amount`) as safe for pushdown into `security_barrier` views and RLS policies.

## File Layout

```text
07_multimodule_and_procedures/
├── pgxext.json                 # Base metadata (version, relocatable, trusted)
├── README.md
├── src/
│   ├── main.nim                # Entry point, pgxExtension:, pgxInit, ex07_reset_ledger
│   └── billing_ops.nim         # Submodule with pgxInit, PROCEDURE, securityDefiner, and leakproof
└── tests/
    ├── sql/01_demo.sql         # SQL regression test suite
    └── expected/01_demo.out    # Exact expected psql output
```

## Building, Verifying, and Testing

```bash
# 1. Build the extension (.so, .control, .sql, .integrity.json)
pgxtool build-extension examples/07_multimodule_and_procedures

# 2. Verify artifact integrity and Security v2 ELF audit
pgxtool verify examples/07_multimodule_and_procedures

# 3. Run regression tests in Docker (PG 18 or full PG 14–18 matrix)
pgxtool test examples/07_multimodule_and_procedures --pg 18
pgxtool test examples/07_multimodule_and_procedures --all
```

## Installing and Testing Manually in `psql`

> **Note:** Because the directory name begins with digits (`07_...`), you must **double-quote the extension name in SQL** (`"07_multimodule_and_procedures"`).

```bash
pgxtool build-extension examples/07_multimodule_and_procedures
sudo ./examples/07_multimodule_and_procedures/src/install.sh
```

```sql
CREATE EXTENSION "07_multimodule_and_procedures";

SELECT ex07_init_status();
SELECT ex07_is_valid_amount(500);
SELECT ex07_calc_invoice(4, 250);

CALL ex07_reset_ledger();
CALL ex07_post_charge(1500);
SELECT ex07_ledger_total();
```

---

## Schema Snapshots and Incremental Migrations (`0.1.0` → `0.2.0`)

`pgxcrown` includes an automatic **structured snapshot** and migration generation engine for `ALTER EXTENSION ... UPDATE`:

1. **Capturing version `0.1.0`**:
   When running `pgxtool build-extension` with `version = "0.1.0"`, `pgx.nim` records the following under `.pgx_build/`:
   - `.pgx_build/schema_0.1.0.json`: structured JSON snapshot (base types, enums, composite types, function/procedure signatures, and `pgxSql` blocks).
   - `.pgx_build/sql_snapshots/07_multimodule_and_procedures--0.1.0.sql`: exact baseline SQL script for `0.1.0`.
   - `.pgx_build/last_version.txt`: stores `"0.1.0"`.

2. **Upgrading to `0.2.0`**:
   When you bump `version = "0.2.0"` (in `pgxExtension:` / `pgxext.json`), add a new function or enum value, and run `pgxtool build-extension` again:
   - `pgx.nim` detects the `0.1.0 -> 0.2.0` transition, diffs `schema_0.1.0.json` against the new AST, and automatically emits under `migrations/`:
     - `migrations/07_multimodule_and_procedures--0.1.0.sql` (preserving the installable `0.1.0` baseline)
     - `migrations/07_multimodule_and_procedures--0.1.0--0.2.0.sql` (containing `ALTER TYPE ... ADD VALUE IF NOT EXISTS`, `ALTER TYPE ... ADD ATTRIBUTE`, `CREATE OR REPLACE FUNCTION/PROCEDURE`, etc.)
   - If `migrations/<ext>--0.1.0--0.2.0.sql` already exists and was customized manually, `pgx.nim` **never overwrites it**.

3. **Installing and upgrading in PostgreSQL**:
   Both `install.sh` and `pgxtool test` copy `migrations/<ext>--*.sql` into PostgreSQL's `extension/` directory so you can test the real upgrade path in SQL:
   ```sql
   CREATE EXTENSION "07_multimodule_and_procedures" VERSION '0.1.0';
   ALTER EXTENSION "07_multimodule_and_procedures" UPDATE TO '0.2.0';
   ```
