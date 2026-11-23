# Pgxcrown Progressive Examples (01 → 12)

A progressive learning guide for building, auditing, and testing **PostgreSQL 14–18** extensions with **Pgxcrown (Nim + C)**—from basic scalar UDFs to production-grade services featuring RBAC-hardened GUCs, composable hooks, shared memory, Background Workers, Nim plugins, and custom scaffolding templates.

---

## Progressive Learning Path (01 → 12)

| # | Example | Level | Key Features Covered | Requires `shared_preload_libraries`? |
|:-:|:--------|:-----:|:---------------------|:------------------------------------:|
| **01** | [`01_hello_scalar_udf/`](01_hello_scalar_udf/) | Beginner | Typed scalar UDFs, `immutable` / `stable` / `volatile` / `parallelSafe` pragmas, `pgxext.json`, and `pg_regress` catalog checks | No |
| **02** | [`02_defaults_nulls_and_errors/`](02_defaults_nulls_and_errors/) | Beginner | `DEFAULT` parameters, bidirectional `Option[T]`, `{.calledOnNullInput.}` vs `STRICT`, `raisePgError` (`SQLSTATE`), and Panic Shield (`Defect` → `ERROR`) | No |
| **03** | [`03_enums_composites_and_arrays/`](03_enums_composites_and_arrays/) | Intermediate | `{.pure.}` PostgreSQL `ENUM`s, composite `object` types, `seq[T]` / composite arrays, and zero-copy `PgVector[T]` | No |
| **04** | [`04_rich_datatypes_and_jsonb/`](04_rich_datatypes_and_jsonb/) | Intermediate | Native binary and rich types: `JsonNode` (`jsonb`), `PgUuid` (`uuid`), NUL-safe `PgBytea` (`bytea`), `PgNumeric` (`numeric`), and temporal types (`PgDate`, `PgTimestamp`, `PgTimestampTz`, `PgInterval`) | No |
| **05** | [`05_custom_base_type/`](05_custom_base_type/) | Intermediate | Custom SQL base type (`{.pgxType: string.}`), `{.pgxInput.}` / `{.pgxOutput.}`, Mod-97 IBAN validation, comparison operators, and B-tree `OPERATOR CLASS` + index via `pgxSql(..., phase = "post")` | No |
| **06** | [`06_streaming_srf_iterators/`](06_streaming_srf_iterators/) | Intermediate | Overloaded `SETOF` `iterator` SRFs, `O(1)` streaming with early `LIMIT` termination, `Option[string]` SQL `NULL` emission, composite `SETOF` rows, and deterministic `=destroy` ARC cleanup | No |
| **07** | [`07_multimodule_and_procedures/`](07_multimodule_and_procedures/) | Advanced | Multi-module layout (`main.nim` + `billing_ops.nim`), deterministic `{.pgxInit.}`, `{.noSql.}`, `pgxext.json` + `pgxExtension:`, SQL `PROCEDURE` (`CALL`), `{.securityDefiner, searchPath.}`, `{.leakproof.}`, and `0.1.0 → 0.2.0` schema snapshots/migrations | No |
| **08** | [`08_query_builder_and_binary_spi/`](08_query_builder_and_binary_spi/) | Advanced | Fluent parameterized `QueryBuilder` + **Binary SPI v2**: `$1`/`$2` bound params, `fetch[Row]`, `Option[string]` (`NULL` vs `""`), persistent prepared plans (`spiPrepare(..., keep = true)`), and streaming cursors (`spiCursorOpen`/`Fetch`/`Close` & `stream[Row]`) | No |
| **09** | [`09_xact_callbacks_and_savepoints/`](09_xact_callbacks_and_savepoints/) | Advanced | Transaction callbacks (`onPreCommit`, `onCommit`, `onAbort`), subtransaction callbacks (`registerSubXactCallback` for `SAVEPOINT`), `pgxWithLibcAlloc` lifetime isolation, and **Anti-PANIC Shield** | No |
| **10** | [`10_shared_memory_and_bgworker/`](10_shared_memory_and_bgworker/) | Production / Architecture | Shared memory (`{.pgxShared.}`, `initShmemStruct` + `{.pgxShmem.}`), atomics & `LWLock` tranches (`getNamedTranche` + `withLock`), and dynamic `BgWorker` lifecycle (`bgWorker`, `runWorkerLoop`, start/status/stop) | **Yes (`tests/preload`)** |
| **11** | [`11_secure_gucs_and_composable_hooks/`](11_secure_gucs_and_composable_hooks/) | Production / Architecture | RBAC-hardened GUCs (`gcUserset`, `gcSuset`, `superuserOnly`, `reserveGucPrefix`, `SET LOCAL`), composable hooks (`ExecutorEnd` + `ProcessUtility`), 3-layer Security v2 audit (`--require-signature`), and live catalog/ELF SHA-256 attestation (`verifyCatalogIntegrity`, `loadedSoSha256`) | **Yes (`tests/preload`)** |
| **12** | [`12_plugins_and_custom_templates/`](12_plugins_and_custom_templates/) | Production / Architecture | Dual v0.33 extensibility: reusable Nim plugin (`plugin_api`: `pgxSql` `pre`/`post`, `mixin` traits, `registerPgxPluginInit` + Binary SPI v2) and external project scaffolding template (`custom_template/` for `pgxtool new --template`) | No |

---

## Prerequisites

- **Pgxcrown toolchain (`pgxtool`)** and **Nim 2.0+**
- **PostgreSQL server development headers** (when compiling locally with `pgxtool build-extension`)
- **Docker** (for running isolated regression test suites across PostgreSQL 14–18 via `pgxtool test`)

---

## Standard Workflows

Every progressive example follows the same standard layout (`pgxext.json`, `src/main.nim`, `tests/sql/*.sql`, `tests/expected/*.out`, and `README.md`) and can be operated either from inside an example directory (`.`) or by passing its path to `pgxtool`:

### 1. Build an Extension

```bash
cd examples/<dir>
pgxtool build-extension .
```

Or from the repository root:

```bash
pgxtool build-extension examples/<dir>
```

This compiles the shared library (`.so`), generates `<ext>.control`, `<ext>--<ver>.sql`, `<ext>.functions.json`, the `<ext>.integrity.json` manifest, and the installation script `src/install.sh`.

### 2. Verify Security & Integrity (Security v2)

```bash
pgxtool verify .
```

Audits the compiled ELF binary (prohibited OS symbols, `RPATH`/`RUNPATH`, `DT_NEEDED`), validates the SHA-256 hashes of `.so`/`.sql`/`.control`, and—when `PGX_INTEGRITY_KEY` is set—verifies the HMAC-SHA256 signature (`--require-signature`).

### 3. Run Regression Tests on PostgreSQL 14–18 (Docker)

```bash
# Test against a specific PostgreSQL version (e.g., PostgreSQL 18)
pgxtool test . --pg 18

# Test across the full supported matrix (PostgreSQL 14, 15, 16, 17, and 18)
pgxtool test . --all
```

> **Note on `shared_preload_libraries`:** Examples **10** and **11** require preloading into PostgreSQL shared memory at server startup. Their `tests/preload` file instructs `pgxtool test` to configure `shared_preload_libraries` and restart PostgreSQL inside the container automatically before running SQL tests.

### 4. Install and Test Manually in `psql`

```bash
sudo ./examples/<dir>/src/install.sh
```

If the extension requires `shared_preload_libraries`, configure it in `postgresql.conf` (or via `ALTER SYSTEM SET shared_preload_libraries = '<dir>';`) and restart PostgreSQL before running `CREATE EXTENSION`. Because these example directory names start with digits, **always double-quote the extension name in SQL**:

```sql
CREATE EXTENSION "<dir>";
```

### 5. Scaffold a New Project from Templates (`pgxtool new`)

```bash
# List available built-in and external templates
pgxtool list-templates

# Create a production-ready service from the built-in secure-service template
pgxtool new ./my_ext --template secure-service --var guc_prefix=my_svc

# Build, verify, and test the newly scaffolded project
pgxtool build-extension ./my_ext
pgxtool verify ./my_ext
pgxtool test ./my_ext --all
```

---

## Legacy Examples

In addition to the progressive `01`–`12` series, this directory preserves the following benchmark and stress-test workloads:

### [`payment_benchmark.sql`](payment_benchmark.sql)
Generates a realistic 10,000-row transactional `payments` table and `payments_history` archive table for benchmarking Pgxcrown **Background Workers (`pgxWorker` / `bgWorker`)** doing batch archival.

Run directly inside a prebuilt GHCR container:
```bash
docker run -d --name pgxcrown-bench -e POSTGRES_PASSWORD=postgres \
  -v "$PWD/examples":/workspace/examples -w /workspace \
  ghcr.io/luisacosta828/pgxcrown:17

docker exec -i pgxcrown-bench psql -U postgres -f /workspace/examples/payment_benchmark.sql
```

### [`memory_chaos_test/`](memory_chaos_test)
Stress scenario exercising Nim `--mm:arc` memory allocations, PostgreSQL `MemoryContext` cleanup across errors, and SPI guards (`memory_chaos_test.nim` + `test_chaos.sql`).
