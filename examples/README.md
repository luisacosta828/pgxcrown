# Pgxcrown Examples

Runnable SQL workloads and stress tests demonstrating real PostgreSQL extension patterns with Pgxcrown.

## Included Examples

### 1. [`payment_benchmark.sql`](payment_benchmark.sql)
Generates a realistic 10,000-row transactional `payments` table and `payments_history` archive table for benchmarking Pgxcrown **Background Workers (`pgxWorker` / `bgWorker`)** doing batch archival.

Run directly inside a prebuilt GHCR container:
```bash
docker run -d --name pgxcrown-bench -e POSTGRES_PASSWORD=postgres \
  -v "$PWD/examples":/workspace/examples -w /workspace \
  ghcr.io/luisacosta828/pgxcrown:17

docker exec -i pgxcrown-bench psql -U postgres -f /workspace/examples/payment_benchmark.sql
```

### 2. [`memory_chaos_test/`](memory_chaos_test)
Stress scenario exercising Nim `--mm:arc` memory allocations, PostgreSQL `MemoryContext` cleanup across errors, and SPI guards (`memory_chaos_test.nim` + `test_chaos.sql`).
