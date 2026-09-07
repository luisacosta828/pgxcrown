<div align="center">

# 👑 Pgxcrown

### High-Performance, Memory-Safe Native PostgreSQL Extension Framework for Nim

[![Nim Version](https://img.shields.io/badge/Nim-2.0%2B-FFE953?logo=nim&logoColor=white)](https://nim-lang.org/)
[![PostgreSQL Support](https://img.shields.io/badge/PostgreSQL-14%20--%2017-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Release](https://img.shields.io/badge/Release-v0.23.0-00E599?logo=github)](https://github.com/luisacosta828/pgxcrown/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Memory Safety](https://img.shields.io/badge/Safety-Memory%20Safe-success)](#-fail-safe-panic-shield--sqlstate-mapping)

<br/>

<img src="banner.jpg" alt="Pgxcrown Banner" width="100%" />

<br/>

**Pgxcrown** is a modern framework and toolchain for building compiled, native [PostgreSQL](https://www.postgresql.org/) C dynamic libraries (`.so` / `.dll`) using [Nim](https://nim-lang.org/). It combines Nim's expressive syntax, deterministic ARC/ORC memory management, and zero-overhead C code generation with PostgreSQL's low-level engine internals (`postgres.h`, `fmgr.h`, `executor/spi.h`).

</div>

---

## ⚡ Key Highlights

- **Zero-Copy Memory-Mapped Views**: Direct pointer-slice [`PgText`](#1-zero-copy-string-processing-pgtext) (zero allocation, zero `strlen`) and SIMD-aligned [`PgVector[T]`](#2-high-performance-arrays--pgvectort) for high-throughput vector and array processing.
- **Fail-Safe Panic Shield (`0 SIGABRTs`)**: Compiles automatic `PG_TRY` boundaries into every UDF—intercepting panics, overflows, and defects to safely abort transactions without crashing the PostgreSQL backend process.
- **Advanced SQLSTATE Error Mapping**: First-class typed exceptions ([`PgError`](#4-advanced-error-handling--sqlstate-shield) and `PostgresError`) with automatic mapping to standard PostgreSQL error codes (`ERRCODE_DATA_EXCEPTION`, `ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE`, etc.).
- **Fluent In-Database SPI Engine**: Ergonomic, left-to-right query execution (`.scalar()`, `.first()`, `.all()`, `.rows()`, `.run()`) with multi-column `RETURNING` support and zero `discard` boilerplate.
- **Universal Objects & Composite Types**: Pure Nim `object` types automatically generate `CREATE TYPE "Name" AS (...)` DDL with bidirectional binary marshaling (`tupleHeaderToObject`, `objectToDatum`).
- **Declarative Custom Base Types**: Declarative pragmas (`{.pgxType.}`, `{.pgxInput.}`, `{.pgxOutput.}`) supporting 15 flat scalar types with type-specific parsing and automatic DDL generation.
- **Smart Incremental Toolchain (`pgxtool`)**: Sub-15ms incremental builds via SHA-256 source manifests, isolated `.pgx_build/nimcache`, and ephemeral Docker container testing across PostgreSQL 14–17 with golden snapshot diffing (`--bless`).
- **Compile-Time Effect Verification**: Static enforcement of SQL volatility (`{.immutable.}`, `{.stable.}`, `{.volatile.}`) preventing illegal database writes at compile time.

---

## 🚀 60-Second Quickstart

### 1. Install via Nimble
```bash
nimble install -y pgxcrown
```

### 2. Scaffold a New Project
```bash
pgxtool init
pgxtool create-project analytics
```

### 3. Write Your Nim Logic (`analytics/src/main.nim`)
```nim
import pgxcrown
import std/[options, json]

type
  UserStats* = object
    userId*: int32
    username*: string
    score*: float64
    verified*: bool

# Pure calculation: Zero-copy text view, IMMUTABLE & PARALLEL SAFE
proc format_badge*(name: PgText, score: float64): string {.immutable, parallelSafe.} =
  if score >= 90.0:
    return "⭐ Gold: " & $name
  return "Bronze: " & $name

# In-database SPI query: STABLE
proc get_top_stats*(minScore: float64): seq[UserStats] {.stable.} =
  let u = table("users", "u")
  let q = Select(u.id as "userId", u.username, u.score, u.active as "verified")
    .From(u)
    .Where(u.score >= minScore and u.active == true)
    .OrderBy(u.score.desc)
    .Limit(25)
  return q.fetch(UserStats)
```

### 4. Test in Isolated Docker Containers (PG 14–17)
```bash
# Run regression tests in an ephemeral PostgreSQL 16 container sandbox
pgxtool test analytics

# Or test across the entire multi-version matrix (14, 15, 16, 17)
pgxtool test analytics --all
```

### 5. Build & Install Locally
```bash
# Compile native .so shared library with sub-15ms incremental cache
pgxtool build-extension analytics

# Install into PostgreSQL system directories
sudo ./analytics/src/install.sh
```

---

## 🛠️ Core Capabilities

### 1. Zero-Copy String Processing (`PgText`)

Traditional C UDFs frequently allocate memory or invoke `strlen` to construct Nim strings from PostgreSQL `varlena` text headers. `PgText` maps PostgreSQL `text`, `varchar`, and `bpchar` data directly as a zero-copy pointer slice:

```nim
import pgxcrown
import std/strutils

proc fast_contains*(haystack: PgText, needle: string): bool {.immutable, parallelSafe.} =
  # Zero-copy slicing, zero allocations, direct memcmp:
  return haystack.contains(needle)

proc clean_slug*(input: PgText): string {.immutable, parallelSafe.} =
  # Seamlessly interoperates with std/strutils via implicit converter:
  return input.strip().toLowerAscii().replace(" ", "-")
```

- **Zero Memory Allocations**: Direct access to PostgreSQL's detoasted varlena payload.
- **Standard Library Interoperability**: Implicit conversion to `string` and `toOpenArray` compatibility with `std/strutils`, `std/hashes`, and tables.
- **Fast Return Path**: Returning `PgText` converts directly back to PostgreSQL `Datum` via zero-copy varlena wrappers.

---

### 2. High-Performance Arrays (`PgVector[T]`)

`PgVector[T]` provides direct, zero-copy read access to PostgreSQL 1D arrays (`int4[]`, `float8[]`, `text[]`, etc.) without copying elements into intermediate heap sequences:

```nim
import pgxcrown

proc vector_dot_product*(a, b: PgVector[float64]): float64 {.immutable, parallelSafe.} =
  if a.len != b.len:
    raisePgError("ERRCODE_CARDINALITY_VIOLATION", "Vector dimensions must match")
  var sum = 0.0
  for i in 0 ..< a.len:
    sum += a[i] * b[i]
  return sum
```

- **Zero Allocation**: Operates directly over PostgreSQL's contiguous array buffer.
- **Bound-Checked Indexing**: Safe indexing (`[]`), slicing (`[a..b]`), and iterators (`items`, `pairs`).
- **`openArray` Interop**: Direct compatibility with high-performance linear algebra routines.

---

### 3. Universal Objects & Named Composite Types

Define standard Nim `object` types, and Pgxcrown automatically produces the corresponding `CREATE TYPE "Name" AS (...)` DDL with bidirectional binary serialization:

```nim
import pgxcrown
import std/[options, json]

type
  Person* = object
    id*: int32
    name*: string
    score*: float64
    active*: bool
    metadata*: JsonNode

# Receives a composite type, modifies it, and returns it
proc update_score*(p: Person, bonus: float64): Person {.immutable, parallelSafe.} =
  result = p
  result.score = p.score + bonus
```

**Auto-Generated PostgreSQL DDL:**
```sql
CREATE TYPE "Person" AS (
  "id" int4,
  "name" Text,
  "score" float8,
  "active" boolean,
  "metadata" jsonb
);

CREATE OR REPLACE FUNCTION update_score("Person", float8) RETURNS "Person"
AS 'analytics', 'pgx_update_score'
LANGUAGE c IMMUTABLE PARALLEL SAFE STRICT;
```

---

### 4. Advanced Error Handling & SQLSTATE Shield

Pgxcrown wraps all UDFs with an automated `PG_TRY` / `PG_CATCH` safety boundary. Unhandled defects and panics (integer overflows, nil dereferences, out-of-bounds access) are intercepted and converted into clean PostgreSQL transaction aborts (`0 SIGABRTs`):

```nim
import pgxcrown

proc transfer_credits*(userId: int32, amount: int64): bool {.volatile.} =
  if amount <= 0:
    raisePgError(ERRCODE_INVALID_PARAMETER_VALUE, "Credit transfer amount must be strictly positive")
  if amount > 1_000_000:
    raisePgError(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE, "Credit limit exceeded for single transaction")
  # Business logic...
  return true
```

#### SQLSTATE Error Code Mapping

| Exception Type | PostgreSQL SQLSTATE | SQL Error Name |
| :--- | :--- | :--- |
| `OverflowDefect` | `22003` | `ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE` |
| `DivByZeroDefect` | `22012` | `ERRCODE_DIVISION_BY_ZERO` |
| `IndexDefect` | `2202E` | `ERRCODE_ARRAY_SUBSCRIPT_ERROR` |
| `ValueError` | `22023` | `ERRCODE_INVALID_PARAMETER_VALUE` |
| `KeyError` | `22000` | `ERRCODE_DATA_EXCEPTION` |
| `PgError` | *User Defined* | Custom SQLSTATE (e.g. `23505`, `22001`) |

---

### 5. Type-Safe SQL Query Builder & Fluent SPI

Execute in-database SQL operations via PostgreSQL's Server Programming Interface (SPI) with zero network latency and fluent left-to-right method chaining:

```nim
import pgxcrown

proc get_department_summary*(minSalary: int32 = 60000): string =
  let e = table("employees", "e")
  let d = table("departments", "d")

  let deptStats = Select(e.dept_id, avg(e.salary) as "avg_sal")
    .From(e)
    .GroupBy(e.dept_id)

  let q = WithCte("dept_stats", deptStats)
    .Select(
      e.id as "emp_id",
      e.name as "emp_name",
      d.name as "dept_name",
      caseWhen(e.salary >= 100000).then("Senior").elseEnd("Associate") as "tier",
      rowNumber().over(partitionBy = e.dept_id, orderBy = e.salary.desc) as "rank"
    )
    .From(e)
    .InnerJoin(d).On(e.dept_id == d.id)
    .Where(e.status == "active" and e.salary >= minSalary)
    .OrderBy(e.salary.desc.nullsLast)
    .Limit(25)

  return $q
```

#### In-Database Fluent SPI Execution
```nim
# 1. Clean DML Execution (No 'discard' required!)
InsertInto("users", "name", "score").Values("'luis'", "98.5").run()

# 2. DML with RETURNING (Scalar or Entity)
let newId = InsertInto("users", "name").Values("'ada'").Returning("id").scalar(int32)

# 3. Typed Reading (.scalar, .first, .all, .rows)
let userCount = Select(count(u.id)).From(u).scalar(int)
let topUsers  = Select(u.id, u.username, u.score).From(u).OrderBy(u.score.desc).all(UserStats)
```

---

## 💻 `pgxtool` CLI Reference

`pgxtool` automates the entire PostgreSQL extension lifecycle:

| Command | Usage | Description |
| :--- | :--- | :--- |
| **`init`** | `pgxtool init` | Initializes the local extension workspace directory (`~/.pgxtool`). |
| **`create-project`** | `pgxtool create-project <name>` | Scaffolds a new extension project directory, `main.nim`, and test templates. |
| **`build-extension`** | `pgxtool build-extension <name> [options]` | Compiles Nim to `.so` shared library, runs security audit, and generates DDL. |
| | `--clean` | Cleans previous build artifacts and cache before compiling. |
| | `--force` (`-f`) | Ignores incremental cache and forces complete recompilation. |
| | `--verbose` (`-v`) | Displays verbose compiler invocations and compilation flags. |
| **`clean`** | `pgxtool clean <name>` | Removes build cache (`.pgx_build`) and generated artifacts (`.so`, `.sql`, `.control`). |
| **`install`** | `pgxtool install <name>` | Automatically copies `.so`, `.control`, and `.sql` to PostgreSQL directories. |
| **`create-type`** | `pgxtool create-type <name> --base-type <type>` | Generates a custom distinct base type with dynamic parsing for 15 scalar types. |
| **`create-hook`** | `pgxtool create-hook <name>` | Scaffolds a Postgres kernel hook template (`emit_log`, `post_parse_analyze`). |
| **`test`** | `pgxtool test <name> [--pg <v>] [--all] [--bless]` | Spawns isolated Docker containers (PG 14–17) to run SQL regression tests. |

---

## 📊 Supported Type Mappings

| Nim Type | PostgreSQL Type | Generated SQL DDL | Zero-Copy Support |
| :--- | :--- | :--- | :---: |
| `PgText` | `TEXT` / `VARCHAR` | `Text` | ✅ Yes |
| `PgVector[T]` | `T[]` | `int4[]`, `float8[]`, `text[]` | ✅ Yes |
| `string` / `cstring` | `TEXT` | `Text` / `cstring` | Transparent |
| `int32` / `int` | `INTEGER` | `int4` | Native |
| `int64` | `BIGINT` | `int8` | Native |
| `int16` | `SMALLINT` | `int2` | Native |
| `float64` / `float` | `DOUBLE PRECISION` | `float8` | Native |
| `float32` | `REAL` | `float4` | Native |
| `bool` | `BOOLEAN` | `boolean` | Native |
| `JsonNode` | `JSONB` | `jsonb` | Native Binary FFI |
| `Option[T]` | Nullable Type | `type DEFAULT NULL` | Native |
| `seq[T]` (Return) | `SETOF T` | `RETURNS SETOF <type>` | Streamed |
| `type T = distinct Base` | Domain Type (`pgxType`) | `CREATE TYPE "T" (...)` | Native |
| `type T = object` | Composite Type | `CREATE TYPE "T" AS (...)` | Binary Serialized |
| `type T = enum` | ENUM Type | `CREATE TYPE "T" AS ENUM (...)` | Native |

---

## 🖥️ Platform & System Requirements

- **Operating System**: Linux (`x86_64`, `aarch64`), macOS. *(Windows: use WSL2 or Docker).*
- **PostgreSQL**: Version 12, 13, 14, 15, 16, or 17 (with `postgresql-server-dev-*` or `pg_config`).
- **Nim Compiler**: Version $\ge 2.0.0$.
- **C Compiler**: GCC or Clang.
- **Docker** *(optional)*: Required for running `pgxtool test` multi-version container sandboxes.

---

## 📄 License

[MIT License](LICENSE) © 2026 Luis Acosta
