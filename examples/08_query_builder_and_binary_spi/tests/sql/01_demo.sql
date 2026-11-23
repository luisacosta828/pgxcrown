\set VERBOSITY terse

CREATE TABLE ex08_orders (
  id serial PRIMARY KEY,
  code text NOT NULL,
  note text,
  amount bigint NOT NULL
);

CREATE TABLE ex08_items (
  id serial PRIMARY KEY,
  sku text NOT NULL,
  qty int4 NOT NULL
);

INSERT INTO ex08_items (sku, qty) VALUES
  ('CPU-01', 4),
  ('RAM-16', 12),
  ('CPU-01', 6),
  ('SSD-1T', 2);

-- 1. Distinguishing SQL NULL vs empty string '' and SQLi-safe parameterization
SELECT ex08_insert_order('ORD-EMPTY', '', 100) AS id_empty;
SELECT ex08_insert_order('ORD-NULL', NULL, 200) AS id_null;
SELECT ex08_insert_order('ORD-SQLI', $sql$'; DROP TABLE ex08_orders; --$sql$, 300) AS id_sqli;

SELECT ex08_inspect_orders(0) AS all_orders;

-- 2. Parameterized UPDATE ... RETURNING and filtered fetch
SELECT ex08_update_order_amount('ORD-EMPTY', 250) AS updated_amount;
SELECT ex08_inspect_orders(250) AS high_value_orders;

-- 3. Kept prepared plan (spiPrepare keep = true + fetchPlan)
SELECT ex08_prepare_sku_plan() AS plan_kept;
SELECT ex08_lookup_sku('CPU-01') AS cpu_batches;

-- 4. Streaming cursors (spiCursorOpen/Fetch/Close + QueryBuilder stream)
SELECT ex08_stream_summary(4, 2) AS stream_summary;
SELECT count(*) AS open_cursors_after FROM pg_cursors;
