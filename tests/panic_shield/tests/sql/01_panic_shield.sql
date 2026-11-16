-- Panic Shield regression suite: trap all Nim Defects/Errors deterministically via DO blocks
CREATE TEMP TABLE panic_results (label text, msg text);

DO $$ BEGIN PERFORM proof_integer_overflow(2147483647, 1);
EXCEPTION WHEN OTHERS THEN INSERT INTO panic_results VALUES ('1_overflow', SQLERRM); END $$;

DO $$ BEGIN PERFORM proof_index_out_of_bounds(5);
EXCEPTION WHEN OTHERS THEN INSERT INTO panic_results VALUES ('2_index', SQLERRM); END $$;

DO $$ BEGIN PERFORM proof_value_conversion('invalid_number');
EXCEPTION WHEN OTHERS THEN INSERT INTO panic_results VALUES ('3_value', SQLERRM); END $$;

DO $$ BEGIN PERFORM proof_range_boundary(500);
EXCEPTION WHEN OTHERS THEN INSERT INTO panic_results VALUES ('4_range', SQLERRM); END $$;

SELECT label, msg FROM panic_results ORDER BY label;
SELECT proof_null_datum('') AS empty_str;
SELECT proof_null_datum('Pgxcrown') AS valid_str;
SELECT proof_integer_overflow(10, 32) AS valid_sum;
SELECT proof_index_out_of_bounds(1) AS valid_item;
SELECT proof_range_boundary(42) AS valid_range;
SELECT 'server alive after 4 panics' AS status;
