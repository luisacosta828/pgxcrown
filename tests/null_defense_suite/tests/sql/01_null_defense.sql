-- Non-STRICT NULL-datum defense regression suite
SELECT safe_greet(NULL) AS greet_null;
SELECT safe_greet('Postgres') AS greet_val;
SELECT safe_add(10, NULL) AS add_null;
SELECT safe_add(10, 32) AS add_vals;
SELECT safe_sum_array(NULL) AS sum_null_arr;
SELECT safe_sum_array(ARRAY[1, 2, 3, 4]) AS sum_arr;
SELECT option_add(25, NULL) AS opt_add_null;
SELECT option_add(25, 17) AS opt_add_some;
