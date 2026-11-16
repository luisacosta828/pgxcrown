-- Runtime security exploit defense regression suite (IndexDefect, OverflowDefect, NULL safety)
CREATE TEMP TABLE sec_results (label text, msg text);

DO $$ BEGIN PERFORM exploit_index_overflow(9999);
EXCEPTION WHEN OTHERS THEN INSERT INTO sec_results VALUES ('1_index_overflow', SQLERRM); END $$;

DO $$ BEGIN PERFORM exploit_integer_overflow(2147483647, 100);
EXCEPTION WHEN OTHERS THEN INSERT INTO sec_results VALUES ('2_int_overflow', SQLERRM); END $$;

SELECT label, msg FROM sec_results ORDER BY label;
SELECT exploit_index_overflow(2) AS safe_elem;
SELECT exploit_integer_overflow(100, 23) AS safe_sum;
SELECT exploit_null_dereference(NULL) AS null_safe;
SELECT exploit_null_dereference('pgxcrown') AS valid_val;
