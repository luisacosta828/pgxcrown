<div align="center">

# 👑 Pgxcrown

### High-Performance, Memory-Safe Native PostgreSQL Extension Framework for Nim

[![Build](https://github.com/luisacosta828/pgxcrown/actions/workflows/build.yml/badge.svg)](https://github.com/luisacosta828/pgxcrown/actions/workflows/build.yml)
[![Nim Version](https://img.shields.io/badge/Nim-2.0%2B-FFE953?logo=nim&logoColor=white)](https://nim-lang.org/)
[![PostgreSQL Support](https://img.shields.io/badge/PostgreSQL-14%20--%2017-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Release](https://img.shields.io/badge/Release-v0.28.0-00E599?logo=github)](https://github.com/luisacosta828/pgxcrown/releases)
[![GHCR Containers](https://img.shields.io/badge/GHCR-PG%2014%20--%2017-2496ED?logo=docker&logoColor=white)](https://github.com/luisacosta828/pgxcrown/pkgs/container/pgxcrown)
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
- **PostgreSQL-Integrated Allocator (`0 Leaks on Abort`)**: Dynamic allocations (`seq`, `string`, `ref object`) route transparently to PostgreSQL's `MemoryContext` (`palloc`). If a query is aborted or cancelled (`siglongjmp`), 100% of memory is reclaimed instantly.
- **Fail-Safe Panic Shield (`0 SIGABRTs`)**: Compiles automatic `PG_TRY` boundaries into every UDF—intercepting panics, overflows, and defects to safely abort transactions without crashing the PostgreSQL backend process.
- **Advanced SQLSTATE Error Mapping**: First-class typed exceptions ([`PgError`](#4-advanced-error-handling--sqlstate-shield) and `PostgresError`) with automatic mapping to standard PostgreSQL error codes (`ERRCODE_DATA_EXCEPTION`, `ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE`, etc.).
- **Fluent In-Database SPI Engine**: Ergonomic, left-to-right query execution (`.scalar()`, `.first()`, `.all()`, `.rows()`, `.run()`) with multi-column `RETURNING` support and zero `discard` boilerplate.
- **Universal Objects & Composite Types**: Pure Nim `object` types automatically generate `CREATE TYPE "Name" AS (...)` DDL with bidirectional binary marshaling (`tupleHeaderToObject`, `objectToDatum`).
- **Declarative Custom Base Types**: Declarative pragmas (`{.pgxType.}`, `{.pgxInput.}`, `{.pgxOutput.}`) supporting 15 flat scalar types with type-specific parsing and automatic DDL generation.
- **Smart Incremental Toolchain (`pgxtool`)**: Sub-15ms incremental builds via SHA-256 source manifests, isolated `.pgx_build/nimcache`, and ephemeral Docker container testing across PostgreSQL 14–17 with golden snapshot diffing (`--bless`).
- **Autonomous Background Workers (`pgxWorker`)**: In-database daemons with sub-1ms dynamic launch (`bgw_notify_pid`), zero-lock live observability (`workerActivity` in `pg_stat_activity`), nested subtransactions (`workerSavepoint`), automatic catalog tracking (`pgxcrown_workers`), and graceful signal shutdown (`onShutdown`).
- **Multi-Process Shared Memory & IPC (`PG 14–17`)**: Declarative static shared state ([`{.pgxShared.}`](#8-multi-process-concurrency--shared-memory-pg-1417)), dynamic shared memory (`dsm`, `shm_toc`), typed SPSC queues & one-line worker RPC (`ShmChannel[T]`, `callWorker`, `withWorkerChannel`), `LWLock` / `SpinLock` / atomics / `ConditionVariable` (`waitUntil`), and `WaitEventSet` latch+socket multiplexing — all compile-time POD-verified and ABI-safe across PostgreSQL 14–17.
- **Compile-Time Effect Verification**: Static enforcement of SQL volatility (`{.immutable.}`, `{.stable.}`, `{.volatile.}`) preventing illegal database writes at compile time.

---

## 🚀 60-Second Quickstart

### 1. Install `pgxtool`

**Option A — Docker-only standalone binary (no Nim or host PostgreSQL headers needed):**
```bash
# Linux x86_64 (static binary)
mkdir -p ~/.local/bin
curl -fL https://github.com/luisacosta828/pgxcrown/releases/latest/download/pgxtool-linux-amd64 -o ~/.local/bin/pgxtool
chmod +x ~/.local/bin/pgxtool

# macOS Apple Silicon (arm64)
# curl -fL https://github.com/luisacosta828/pgxcrown/releases/latest/download/pgxtool-darwin-arm64 -o /usr/local/bin/pgxtool && chmod +x /usr/local/bin/pgxtool
```

**Option B — Full host toolchain via Nimble (for local `build-extension` + Docker):**
```bash
nimble install -y pgxcrown
```

### 2. Scaffold & Test Immediately (Working Starter Included)
```bash
pgxtool init
pgxtool create-project analytics
pgxtool test analytics --pg 17   # compiles inside GHCR & runs SQL regression tests!
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
# Run regression tests in an ephemeral PostgreSQL 16 sandbox (or pick 14/15/17)
pgxtool test analytics
pgxtool test analytics --pg 17

# Run directly inside the extension directory (CWD mode) or via explicit path
(cd analytics && pgxtool test --pg 14)
pgxtool test ./analytics --pg 15 --bless

# Or test across the entire multi-version matrix (14, 15, 16, 17)
pgxtool test analytics --all

# Force pulling/using the official GHCR image repository explicitly
PGXCROWN_IMAGE=ghcr.io/luisacosta828/pgxcrown pgxtool test analytics --pg 17
```

> **Note:** When installed via `nimble install -y pgxcrown` outside a git checkout, `pgxtool test` automatically pulls `ghcr.io/luisacosta828/pgxcrown:<pg>`. Inside a repository checkout, it reuses local `pgxcrown:<pg>` / GHCR images or builds `docker/Dockerfile` automatically if missing.

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
| `KeyError` | `P0002` | `ERRCODE_NO_DATA_FOUND` |
| `PgError` | *User Defined* | Custom SQLSTATE (e.g. `23505`, `22001`) |

---

### 5. PostgreSQL-Integrated Memory Management & RAII Contexts

Pgxcrown seamlessly couples Nim's ARC/ORC runtime with PostgreSQL's hierarchical `MemoryContext` system via GNU `ld` linker wrapping (`--wrap=malloc,free,...`). All standard heap allocations (`string`, `seq[T]`, `ref object`) born inside an extension transparently allocate inside PostgreSQL's active `CurrentMemoryContext`.

#### Why This Matters (Zero Leaks on Cancellation):
When PostgreSQL aborts a query (via `statement_timeout`, client disconnection, or `pg_cancel_backend()`), it executes a hardware-level `siglongjmp` back to the main query dispatcher. This skips standard language destructors. With Pgxcrown's custom allocator, **PostgreSQL's `AtError_Memory()` automatically sweeps and reclaims 100% of Nim's memory in $O(1)$**, preventing cumulative memory leaks in long-running backend connections.

#### Case 1: Everyday Transparent Usage (Zero Boilerplate)
Write standard, idiomatic Nim code. You don't manage pointers, call `palloc`, or manually free anything:

```nim
import pgxcrown

proc parse_tags*(raw: PgText): seq[string] =
  # All allocations (seq, strings, split) born in CurrentMemoryContext
  var tags = newSeq[string]()
  for item in raw.toString().split(','):
    tags.add("tag: " & item.strip())
  return tags
  # Upon query completion or abort, memory is reclaimed automatically by PostgreSQL.
```

#### Case 2: Long-Lived Global Caches (`withTopMemoryContext`)
Per-tuple or per-query memory contexts are reset after each row or statement. To store lookup tables, ML models, or configurations that must survive across queries for the entire duration of the client connection, use `withTopMemoryContext`:

```nim
import pgxcrown
import pgxcrown/memcontext
import std/tables

var gConfigCache {.global.}: Table[string, string]
var gInitialized {.global.} = false

proc get_setting*(key: PgText): PgText =
  if not gInitialized:
    # Memory allocated within this block lives in TopMemoryContext:
    withTopMemoryContext:
      gConfigCache = initTable[string, string]()
      gConfigCache["timeout_ms"] = "5000"
      gConfigCache["region"] = "us-east-1"
      gInitialized = true

  return returnPgText(gConfigCache.getOrDefault(key.toString(), "not_found"))
```

#### Case 3: Heavy Ephemeral Computations (`withSubContext`)
When processing large payloads (e.g. parsing a 100MB JSON document), allocating millions of temporary strings inside the query's main context can cause transient memory spikes. Use `withSubContext` to isolate the scratchpad:

```nim
import pgxcrown
import pgxcrown/memcontext

proc extract_summary*(hugePayload: PgText): int32 =
  var resultCount = 0

  # Creates an isolated child memory context, executes body, and deletes it in finally:
  withSubContext("bulk_parser_ctx"):
    let parsedNodes = parseHeavyData(hugePayload.toString())
    resultCount = parsedNodes.len

  # Child context is destroyed here—RAM returns to baseline BEFORE query finishes!
  return resultCount.int32
```

---

### 6. Type-Safe SQL Query Builder & Fluent SPI

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

### 7. Autonomous Background Workers (In-Database Daemons)

Deploy persistent or dynamic background processes directly inside PostgreSQL using pure Nim—with zero `Datum` leaks, instant startup, real-time DBA observablity, and failure isolation:

- **Declarative DSL (`bgWorker`)**: Configure entrypoints, target databases, and restart policies without handling raw C structs.
- **Instant (~1ms) Dynamic Startup**: Module-level `MyProcPid` binding ensures instant `SIGUSR1` wake-up from the Postmaster.
- **Zero-Lock Live Observability (`workerActivity`)**: Reports real-time status into `pg_stat_activity` (`query` and `state` columns) without table locks or performance degradation.
- **Subtransactions & Savepoints (`workerSavepoint`)**: Isolate per-record failures during batch runs without aborting the parent transaction.
- **Catalog Tracking & Lifecycle SQL**: Automatically registers PID and status in `pgxcrown_workers` and exposes `start_<name>_worker()`, `stop_<name>_worker()`, and `<name>_worker_status()` functions to SQL.
- **Graceful Shutdown (`onShutdown`)**: Cleanly intercepts `SIGTERM` and auto-reconciles the catalog before process exit.

```nim
import pgxcrown

type
  OrderRecord* = object
    id*: int
    customer*: string
    amount*: float
    status*: string

# Background Worker Daemon Entrypoint
proc order_archiver_worker*() {.pgxWorker.} =
  workerInit("postgres")

  let orders = table("orders")
  let vencidos = table("vencidos")

  runWorkerLoop(intervalMs = 5000):
    workerActivity("Checking expired orders"):
      workerTransaction:
        # Type-safe CTE pipeline
        let expired = WithCte("vencidos",
          Select(orders.id, orders.customer, orders.amount, orders.status)
            .From(orders)
            .Where(orders.status == "vencido")
        )
          .Select(vencidos.id, vencidos.customer, vencidos.amount, vencidos.status)
          .From(vencidos)
          .all(OrderRecord)

        if expired.len > 0:
          workerActivity("Archiving " & $expired.len & " expired orders"):
            for exp in expired:
              let order = exp
              # Subtransaction savepoint: errors in one record do not fail the entire batch!
              workerSavepoint:
                InsertInto("orders_history", "id", "customer", "amount", "status")
                  .Values($order.id, quoteLiteral(order.customer), $order.amount, quoteLiteral(order.status))
                  .run()
                DeleteFrom("orders").Where(orders.id == order.id).run()
              do:
                pgWarning("Failed to archive order " & $order.id & ": " & err.msg)
  do:
    pgNotice("OrderArchiver worker cleanly shut down.")

# SQL Launcher Function (dynamically starts worker)
proc start_order_archiver_worker*(): int32 {.volatile.} =
  let cfg = bgWorker("order_archiver"):
    database "postgres"
    restart 30
  let handle = registerDynamicWorker(cfg)
  if handle.isSome:
    let (status, pid) = handle.get.waitForStartup()
    if status == bgwStarted:
      trackWorkerStarted("order_archiver", pid)
      return pid.int32
  return -1'i32

# SQL Graceful Stop Function
proc stop_order_archiver_worker*(): bool {.volatile.} =
  return stopWorkerByName("order_archiver")

# SQL Live Status Function
proc order_archiver_worker_status*(): string {.volatile.} =
  return getWorkerStatusByName("order_archiver")
```

#### SQL Management & Live Monitoring:
```sql
-- Start worker and retrieve PID:
SELECT start_order_archiver_worker();

-- Live observability in pg_stat_activity:
SELECT pid, state, query, wait_event 
FROM pg_stat_activity 
WHERE backend_type = 'order_archiver';

-- Query catalog status:
SELECT * FROM pgxcrown_workers;
SELECT order_archiver_worker_status(); -- Returns 'running' or 'stopped'

-- Stop worker cleanly via SQL:
SELECT stop_order_archiver_worker();
```

---

### 8. Multi-Process Concurrency & Shared Memory (`PG 14–17`)

Every PostgreSQL session and Background Worker runs in a separate OS process (`fork()`), with private per-process `MemoryContext` heaps (`--mm:arc`/`orc`). Pgxcrown provides compile-time POD-guarded primitives and high-level ergonomics unified across **PostgreSQL 14, 15, 16, and 17** (`pgxcrown/lwlock`, `pgxcrown/shmem`, `pgxcrown/shm_mq`, and `WaitEventSet` in `pgxcrown/bgworker` — all automatically re-exported by `import pgxcrown`).

#### When to Use Which Tool

| Need / Workload | Recommended API | `shared_preload_libraries` Required? | Notes |
| :--- | :--- | :---: | :--- |
| **Global counters, metrics, caches or flags** shared across all sessions & static workers | `{.pgxShared.}` (or `installShmemHooks` + `initShmemStruct`) | **Yes** | Allocated once at Postmaster startup (`shmem_request_hook` on PG 15–17, `_PG_init` on PG 14); survives across queries. |
| **One-shot or batched typed RPC** between a SQL session and a dynamic worker | `proc w(req): resp {.pgxWorker.}` + `callWorker[TResp]` / `withWorkerChannel` | **No** | Works with `CREATE EXTENSION` alone; hides DSM, `shm_toc`, `ResetLatch`, and worker cleanup. |
| **Streaming / custom multi-queue DSM layout** (e.g., mixed `LWLock` + ring queues + variable payloads) | `dsmCreate` + `shm_toc` + `ShmChannel[T]` / `send`/`receive` | **No** | Full control over segment pinning, `ShmRpcChannel`, zero-copy reads, and byte/string payloads. |
| **Cluster-wide synchronization & async I/O** | `pg_atomic_*`, `withLock`, `withSpinLock`, `waitUntil`, `withWaitEventSet` | Depends on storage | Handles atomics, LWLocks, CVs, and non-blocking socket + `MyLatch` multiplexing safely. |

> [!IMPORTANT]
> **Compile-Time POD Rule (`{.pgxShared.}` / `{.pgxShmem, bycopy.}`):**
> Types stored in static shared memory, DSM, or `ShmChannel[T]` must be plain C-ABI data (`supportsCopyMem(T) == true`). Putting Nim heap types (`string`, `seq`, `Table`, `ref`) inside shared memory causes compile errors intentionally—use `FixedString[N]` for text buffers and `pgSizeOf[T]()` (real C `sizeof`) for sizing. Mark shared-memory structs with `{.pgxShared.}` (or `{.pgxShmem, bycopy.}`) so Pgxcrown does **not** emit a SQL `CREATE TYPE` for them.

#### Case A: Cluster-Wide Shared State with `{.pgxShared.}` (Preloaded Extension)

Use `{.pgxShared.}` when multiple client connections and/or static background workers read and mutate the same live state in RAM from Postmaster startup:

```nim
import pgxcrown

type
  ServiceMetrics* {.pgxShared.} = object
    requests*: pg_atomic_uint64
    tag*: FixedString[24]

proc initMetrics(p: ptr ServiceMetrics) =
  p.requests.init(0'u64)
  p.tag.setStr("ready")

# Auto-reserves shmem, hooks _PG_init / shmem_request / shmem_startup, and runs initMetrics once:
var metrics* {.pgxShared("my_ext_metrics", initMetrics).}: ServiceMetrics

proc record_hit*(): string {.volatile.} =
  let total = metrics.requests.addFetch(1)
  result = $metrics.tag & ":" & $total
```

Enable preload testing automatically by adding an empty `tests/preload` marker file in your extension project (so `pgxtool test my_ext --all` restarts PostgreSQL with `shared_preload_libraries = 'my_ext'`), or pass `--preload` explicitly:

```bash
touch my_ext/tests/preload
pgxtool test my_ext --all --bless -v
# Or manually for any extension/hook:
pgxtool test my_ext --pg 17 --preload -v
```

*(Need a custom named `LWLockTranche` or static worker alongside `{.pgxShared.}`? Define `proc my_init() {.pgxInit.}` and call `installShmemHooks(onReq, onStart)` + `registerWorker(cfg)` — Pgxcrown chains your hooks cleanly alongside all `{.pgxShared.}` slots across PG 14–17.)*

#### Case B: Dynamic Typed Worker RPC (`callWorker` & `withWorkerChannel` — No Preload)

When a SQL session needs to offload work or talk to an on-demand worker without modifying `postgresql.conf`, declare a typed `{.pgxWorker.}` handler `(req: TReq): TResp` and invoke `callWorker[TResp]` (or reuse a live worker across multiple requests with `withWorkerChannel`):

```nim
import pgxcrown

type
  ComputeReq* {.pgxShared.} = object
    a*: int64
    b*: int64

  ComputeResp* {.pgxShared.} = object
    sum*: int64
    product*: int64

# 1. Define a typed RPC worker (DSM, ResetLatch, CHECK_FOR_INTERRUPTS & cleanup are automatic):
proc math_worker*(req: ComputeReq): ComputeResp {.pgxWorker.} =
  ComputeResp(sum: req.a + req.b, product: req.a * req.b)

# 2. One-shot call from SQL (infers ComputeReq automatically):
proc remote_add*(x: int64, y: int64): int64 {.volatile.} =
  let res = callWorker[ComputeResp]("my_ext", "math_worker", ComputeReq(a: x, b: y))
  return res.sum

# 3. Batched multi-call session reusing one live background worker:
proc remote_batch_sum*(n: int64): int64 {.volatile.} =
  withWorkerChannel(ch, ComputeReq, ComputeResp, "my_ext", "math_worker"):
    for i in 1 .. n:
      result += ch.call(ComputeReq(a: i, b: i * 2)).sum
```

#### Case C: Synchronization, Condition Variables & `WaitEventSet` Multiplexing

Choose the synchronization primitive that matches your critical section rules:

- **Lock-free counters/flags:** `pg_atomic_uint32`, `pg_atomic_uint64`, `pg_atomic_flag` (`init`, `load`, `store`, `addFetch`, `compareExchange`).
- **General critical sections (`withLock`):** Wraps PostgreSQL `LWLock` (`rwlock`: `lwExclusive` / `lwShared`) inside `try ... finally` so exceptions or `ereport(ERROR)` never leave locks dangling. Safe with `palloc`, SPI, and dynamic DSM tranches (`newTrancheId` + `registerTrancheCopy` per attaching process).
- **Ultra-short critical sections (`withSpinLock`):** Minimal overhead on `slock_t`. **Never allocate memory (`palloc`), call `ereport`, or run SPI inside `withSpinLock`** (a `siglongjmp` would leave a spinlock wedged).
- **Condition Variables (`waitUntil`):** Encapsulates `PrepareToSleep -> withLock(check) -> Sleep -> finally: CancelSleep()` without lost wakeups or holding an `LWLock` across sleep:
  ```nim
  let ok = waitUntil(state.cv, lock, lwShared, timeoutMs = 5000):
    state.ticks.load() >= targetTicks
  ```
- **Event Multiplexing (`withWaitEventSet`):** Wait concurrently on `MyLatch`, postmaster death, and **non-blocking** sockets (`setSocketNonBlocking`) portably across PG 14–16 (`TopMemoryContext`) and PG 17 (`ResourceOwner`), handling `wlSocketClosed()` safely on every version:
  ```nim
  withWaitEventSet(wes, 3):
    discard wes.addLatchEvent(MyLatch)
    discard wes.addPostmasterDeathEvent(exitOnDeath = true)
    discard wes.addSocketEvent(sockFd, WL_SOCKET_READABLE or wlSocketClosed())
    var occurred: array[4, WaitEvent]
    let n = wes.waitEventSet(250, occurred)
  ```

---

## 💻 `pgxtool` CLI Reference

`pgxtool` automates the entire PostgreSQL extension lifecycle:

| Command | Usage | Description |
| :--- | :--- | :--- |
| **`init`** | `pgxtool init` | Initializes the local extension workspace directory (`~/.pgxtool`). |
| **`create-project`** | `pgxtool create-project <name>` | Scaffolds a new extension project directory, `main.nim`, and test templates. |
| **`create-worker`** | `pgxtool create-worker <name>` | Scaffolds an autonomous background worker daemon with dynamic launcher and lifecycle functions. |
| **`build-extension`** | `pgxtool build-extension <name> [options]` | Compiles Nim to `.so` shared library, runs security audit, and generates DDL. |
| | `--clean` | Cleans previous build artifacts and cache before compiling. |
| | `--force` (`-f`) | Ignores incremental cache and forces complete recompilation. |
| | `--verbose` (`-v`) | Displays verbose compiler invocations and compilation flags. |
| | `--debug` (`-d`) | Enables `pgxDebug` compile-time AST and DDL debug output. |
| **`clean`** | `pgxtool clean <name>` | Removes build cache (`.pgx_build`) and generated artifacts (`.so`, `.sql`, `.control`). |
| **`install`** | `pgxtool install <name>` | Automatically copies `.so`, `.control`, and `.sql` to PostgreSQL directories. |
| **`create-type`** | `pgxtool create-type <name> --base-type <type>` | Generates a custom distinct base type with dynamic parsing for 15 scalar types. |
| **`create-hook`** | `pgxtool create-hook <name>` | Scaffolds a Postgres kernel hook template (`emit_log`, `post_parse_analyze`). |
| **`test`** | `pgxtool test [project\|path] [--pg <v>] [--all] [--local] [--preload] [--bless] [--keep] [--debug]` | Runs SQL regression tests (with optional `shared_preload_libraries` + restart via `--preload` or `tests/preload`) in Docker/GHCR sandboxes (PG 14–17) or locally (`--local`). |
| **`version`** | `pgxtool --version` | Prints the installed `pgxtool` / `pgxcrown` version. |

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

---

## 🐳 Official Docker & GHCR Images (PostgreSQL 14–17)

Prebuilt all-in-one container images are published to GitHub Container Registry (`ghcr.io/luisacosta828/pgxcrown`, `linux/amd64`). Each image bundles official `postgres:<ver>`, `postgresql-server-dev-<ver>`, `gcc`, **Nim 2.4.0 + Nimble**, and **`pgxcrown` (`pgxtool`)** so engineers and CI runners can compile, install, and test C/Nim PostgreSQL extensions with zero host PostgreSQL setup.

### Published GHCR Image Matrix (`v0.28.0`)

| PostgreSQL Version | Rolling Major Tag | Pinned Release Tag |
| :--- | :--- | :--- |
| **PostgreSQL 17** | `ghcr.io/luisacosta828/pgxcrown:17` / `:latest` | `ghcr.io/luisacosta828/pgxcrown:17-0.28.0` |
| **PostgreSQL 16** | `ghcr.io/luisacosta828/pgxcrown:16` | `ghcr.io/luisacosta828/pgxcrown:16-0.28.0` |
| **PostgreSQL 15** | `ghcr.io/luisacosta828/pgxcrown:15` | `ghcr.io/luisacosta828/pgxcrown:15-0.28.0` |
| **PostgreSQL 14** | `ghcr.io/luisacosta828/pgxcrown:14` | `ghcr.io/luisacosta828/pgxcrown:14-0.28.0` |

### Real-World Workflows

```bash
# 1) Pull any version directly from GHCR
docker pull ghcr.io/luisacosta828/pgxcrown:17

# 2) Compile inside an ephemeral GHCR container (zero host PG/Nim toolchain needed)
docker run --rm -v "$PWD":/workspace -w /workspace \
  ghcr.io/luisacosta828/pgxcrown:17 pgxtool build-extension analytics

# 3) Start a PostgreSQL 17 dev container and compile + install + run SQL tests (--local)
docker run -d --name pgxcrown-17 -e POSTGRES_PASSWORD=postgres -p 5417:5432 \
  -v "$PWD":/workspace -w /workspace ghcr.io/luisacosta828/pgxcrown:17
docker exec -it pgxcrown-17 pgxtool test analytics --local

# 4) Refresh pgxcrown inside an existing container image when a newer release ships
nimble refresh && nimble install -y pgxcrown
```

### How `pgxtool` Resolves Images

1. If `PGXCROWN_IMAGE` is set (e.g. `PGXCROWN_IMAGE=ghcr.io/luisacosta828/pgxcrown`), `pgxtool test` pulls and runs `<PGXCROWN_IMAGE>:<pg>`.
2. Otherwise, if local `pgxcrown:<pg>` or cached `ghcr.io/luisacosta828/pgxcrown:<pg>` already exists locally, it reuses it immediately.
3. Inside a repository checkout containing `docker/Dockerfile`, missing images are built locally as `pgxcrown:<pg>`; outside a checkout (e.g. `nimble install -y pgxcrown`), `pgxtool` automatically pulls `ghcr.io/luisacosta828/pgxcrown:<pg>`.

You can also build images locally with `./docker/build.sh` or orchestrate all four PostgreSQL versions via `docker/compose.yaml`. See [docker/README.md](docker/README.md) for the complete container reference.

---

## 🖥️ Platform & System Requirements

- **Operating System**: Linux (`x86_64`, `aarch64`), macOS. *(Windows: use WSL2 or Docker).*
- **Docker-Only Mode *(Zero Host Setup)***: Only **Docker** + standalone `pgxtool` binary from [Releases](https://github.com/luisacosta828/pgxcrown/releases) (`pgxtool init/create-project/test` automatically pull `ghcr.io/luisacosta828/pgxcrown:{14,15,16,17}`).
- **Host Native Compilation *(Optional)***: PostgreSQL `14`–`17` (`postgresql-server-dev-*` / `pg_config`), Nim Compiler $\ge 2.0.0$, and GCC/Clang.

---

## 📄 License

[MIT License](LICENSE) © 2026 Luis Acosta
