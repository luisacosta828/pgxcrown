CREATE TYPE sb_color AS ENUM ('red', 'green', 'blue');

CREATE TABLE sb_kept_items (
    id int4 PRIMARY KEY,
    tag text NOT NULL,
    qty int4 NOT NULL
);

INSERT INTO sb_kept_items VALUES (1, 'k1', 10), (2, 'k2', 20), (3, 'k1', 30);

CREATE TABLE sb_tx_log (
    id int4 PRIMARY KEY,
    tag text NOT NULL
);

-- 1. NULL vs empty string, TupleDesc metadata caching & dropped column skip
SELECT sb_null_vs_empty() AS res;

-- 2. DML ... RETURNING auto read_only = false + SELECT/VALUES read_only = true
SELECT sb_dml_returning() AS res;

-- 3. Full binary roundtrip (scalars, OID uint32, NaN/Inf, PgText, PgBytea w/ NUL, PgUuid, temporals, PgNumeric, JSON/JSONB, enum OID & text, distinct, arrays, SQLi immunity, bulk inserts, CTEs)
SELECT sb_binary_types_roundtrip() AS res;

-- 4. External plugin pgxFromDatum hook (fetch, scalar, stream, Option)
SELECT sb_custom_hook() AS res;

-- 5. Prepared SpiPlan executePlan, fetchPlan, idempotent free, kept plan across calls
SELECT sb_prepared_plans() AS res;
SELECT sb_init_kept_plan() AS kept_ready;
SELECT sb_kept_plan_fetch('k1') AS kept_k1;
SELECT sb_kept_plan_fetch('k2') AS kept_k2;

-- 6. Streaming cursors, early break / exception cleanup, fetchBatches, manual cursor, batchSize validation
SELECT sb_cursor_streaming() AS res;
SELECT count(*) AS open_cursors_after FROM pg_cursors;

-- 7. Non-atomic PROCEDURE transaction control (spiNonAtomic, spiCommit, spiRollback, spiCommitAndChain, spiRollbackAndChain, error recovery)
SELECT proname, prokind FROM pg_proc WHERE proname = 'sb_nonatomic_tx';
CALL sb_nonatomic_tx(100);
SELECT id, tag FROM sb_tx_log ORDER BY id;

-- 8. NUL byte injection defense
SELECT sb_reject_null_byte() AS res;
