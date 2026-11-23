# Example 06: `O(1)` Streaming SRF Iterators

## What This Example Demonstrates

This example shows how to implement PostgreSQL Set-Returning Functions (`RETURNS SETOF ...`) using Nim `iterator` definitions with constant `O(1)` per-row memory usage:

- **Overloaded iterators (`SETOF int64`)**: `ex06_stream_range(n)` and `ex06_stream_range(startVal, endVal)` share a single SQL name backed by distinct mangled C symbols.
- **`O(1)` streaming and early `LIMIT` termination**: `ex06_stream_range(50000)` and `ex06_stream_range(1000000) LIMIT 3` yield rows lazily without materializing large sequences in memory.
- **SQL `NULL` emission (`Option[string]`)**: `ex06_stream_nullable` yields real SQL `NULL` values whenever the iterator yields `none(string)`.
- **Streaming composite records (`SETOF ex06_event_row`)**: `ex06_stream_events` emits typed multi-column rows directly from a Nim `object`.
- **Deterministic ARC cleanup (`=destroy`) and Panic Shield**: `ex06_stream_guarded` holds an RAII guard with `=destroy` wired to PostgreSQL's `multi_call_memory_ctx` reset callback, ensuring cleanup runs on normal completion, early `LIMIT` termination, and mid-stream exceptions.

## File Layout

```text
06_streaming_srf_iterators/
├── pgxext.json                # Extension metadata (.control)
├── src/
│   └── main.nim               # Overloaded iterators, Option[string], composite rows, and RAII
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Tests for 50k streaming, LIMIT, NULL, composites, and errors
│   └── expected/
│       └── 01_demo.out        # Exact expected psql output
└── README.md
```

## How to Create It from Scratch

### Option A: Using the `starter-udf` template via `pgxtool new`

```bash
pgxtool new ./06_streaming_srf_iterators --template starter-udf
```

Then replace `src/main.nim` with the `*`-exported `iterator` definitions and the `ex06_event_row*` composite type.

### Option B: Step by step manually

```bash
mkdir -p 06_streaming_srf_iterators/src 06_streaming_srf_iterators/tests/sql 06_streaming_srf_iterators/tests/expected
```

1. Configure `pgxext.json` with `"version": "0.1.0"`, `"relocatable": true`, and `"trusted": true`.
2. Implement the `*`-exported iterators in `src/main.nim` (for `int64`, `Option[string]`, `ex06_event_row`, and RAII cleanup).
3. Add `tests/sql/01_demo.sql` and `tests/expected/01_demo.out`.

## Building

```bash
pgxtool build-extension examples/06_streaming_srf_iterators
```

## Verifying Security and Integrity

```bash
pgxtool verify examples/06_streaming_srf_iterators
```

## Running Tests

Run against PostgreSQL 18 in Docker:

```bash
pgxtool test examples/06_streaming_srf_iterators --pg 18
```

Run across the full PostgreSQL 14–18 matrix:

```bash
pgxtool test examples/06_streaming_srf_iterators --all
```

## Installing and Testing Manually in `psql`

```bash
sudo examples/06_streaming_srf_iterators/src/install.sh
```

In `psql`:

```sql
CREATE EXTENSION "06_streaming_srf_iterators";

SELECT * FROM ex06_stream_range(5);
SELECT * FROM ex06_stream_range(10, 14);
SELECT * FROM ex06_stream_nullable('row', 4);
SELECT seq_no, label, is_even FROM ex06_stream_events(4);
SELECT * FROM ex06_stream_guarded(1000, 0) LIMIT 2;
SELECT ex06_cleanup_count();

DROP EXTENSION "06_streaming_srf_iterators";
```
