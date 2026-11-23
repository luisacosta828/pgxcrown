# Example 08: Fluent `QueryBuilder` and Binary SPI v2

This example demonstrates `pgxcrown`'s **Binary SPI v2** layer alongside the typed **`QueryBuilder`**: parameterized execution (`$1`, `$2`, ...), direct binary deserialization into Nim `object` types (`fetch[Row]`), strict distinction between SQL `NULL` and empty string `""` via `Option[string]`, persistent prepared plans (`spiPrepare(..., keep = true)`), and streaming cursors (`spiCursorOpen` / `spiCursorFetch` / `spiCursorClose` and `stream[Row]`).

## What This Example Demonstrates

1. **Parameterized, SQLi-safe `QueryBuilder`**:
   - `InsertInto(...).Values(...).Returning("id").scalar(int32)` and `Update(...).Set(...).Where(...).Returning(...)` pass typed binary parameters (`$1`, `$2`, ...), neutralizing injection payloads such as `'; DROP TABLE ...; --`.
2. **Typed binary deserialization (`fetch[Row]`)**:
   - Decodes PostgreSQL `Datum` values directly into `Ex08OrderRow` / `Ex08ItemRow` without intermediate text conversions.
3. **`Option[string]`: SQL `NULL` vs empty string `""`**:
   - `none(string)` represents SQL `NULL`, while `some("")` preserves the empty string `""` without conflating the two.
4. **Persistent prepared plans (`SpiPlan`)**:
   - `spiPrepare(..., [TEXTOID], keep = true)` keeps the compiled plan pinned in PostgreSQL memory (`SPI_keepplan`) across calls and executes it with `fetchPlan[Row](plan, [toBoundParam(sku)])`.
5. **Streaming cursors (`SpiCursor` and `stream[Row]`)**:
   - `spiCursorOpen` / `spiCursorFetch` / `spiCursorClose` and the `stream[Row](q, batchSize)` iterator process bounded batches using `O(batchSize)` memory and close portals cleanly (`pg_cursors = 0`).

## File Layout

```text
08_query_builder_and_binary_spi/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Building, Verifying, and Testing

```bash
pgxtool build-extension examples/08_query_builder_and_binary_spi
pgxtool verify examples/08_query_builder_and_binary_spi
pgxtool test examples/08_query_builder_and_binary_spi --pg 18
pgxtool test examples/08_query_builder_and_binary_spi --all
```

## Installing and Testing Manually in `psql`

```bash
pgxtool build-extension examples/08_query_builder_and_binary_spi
sudo ./examples/08_query_builder_and_binary_spi/src/install.sh
```

```sql
CREATE EXTENSION "08_query_builder_and_binary_spi";

CREATE TABLE ex08_orders (id serial PRIMARY KEY, code text NOT NULL, note text, amount bigint NOT NULL);
CREATE TABLE ex08_items (id serial PRIMARY KEY, sku text NOT NULL, qty int4 NOT NULL);
INSERT INTO ex08_items (sku, qty) VALUES ('CPU-01', 4), ('CPU-01', 6);

SELECT ex08_insert_order('ORD-EMPTY', '', 100);
SELECT ex08_insert_order('ORD-NULL', NULL, 200);
SELECT ex08_inspect_orders(0);

SELECT ex08_prepare_sku_plan();
SELECT ex08_lookup_sku('CPU-01');
SELECT ex08_stream_summary(4, 2);
```
