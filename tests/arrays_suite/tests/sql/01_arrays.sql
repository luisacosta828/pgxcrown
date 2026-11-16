-- Bidirectional array & composite record[] regression suite
SELECT sum_int_array(ARRAY[10, 20, 30, 40]) AS total;
SELECT double_int_array(ARRAY[1, 2, 3, 4, 5]) AS doubled;
SELECT join_string_array(ARRAY['PostgreSQL', 'Nim', 'Pgxcrown'], ' | ') AS joined;
SELECT uppercase_string_array(ARRAY['alpha', 'beta', 'gamma']) AS upper_words;
SELECT count_true_bools(ARRAY[true, false, true, true, false]) AS true_count;
SELECT count_adults(ARRAY[(25, 'Alice')::"Person", (15, 'Bob')::"Person", (30, 'Charlie')::"Person"]) AS adults;
