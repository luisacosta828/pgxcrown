-- Regression: an error raised AFTER a successful pgTry (SPI) inside the same
-- UDF call must be a clean SQL error, never a backend segfault.
CREATE TEMP TABLE guard_results (label text, msg text);

DO $$ BEGIN PERFORM plain_raise();
EXCEPTION WHEN OTHERS THEN INSERT INTO guard_results VALUES ('1_plain_raise', SQLERRM); END $$;

DO $$ BEGIN PERFORM ok_then_raise();
EXCEPTION WHEN OTHERS THEN INSERT INTO guard_results VALUES ('2_ok_then_raise', SQLERRM); END $$;

DO $$ BEGIN PERFORM ok_then_defect(5);
EXCEPTION WHEN OTHERS THEN INSERT INTO guard_results VALUES ('3_ok_then_defect', SQLERRM); END $$;

SELECT label, msg FROM guard_results ORDER BY label;
SELECT ok_return() AS spi_rows;
SELECT 'still alive' AS status;
