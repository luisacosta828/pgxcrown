-- Default parameters & Option[T] NULL defense regression suite
SELECT test_default_params() AS def_both;
SELECT test_default_params('Nim Developer', 5) AS def_override;
SELECT test_default_bool() AS def_bool_true;
SELECT test_default_bool(false) AS def_bool_false;
SELECT test_option_param(42, NULL) AS opt_null;
SELECT test_option_param(42, 8) AS opt_some;
SELECT test_option_return(-5) AS opt_ret_null;
SELECT test_option_return(10) AS opt_ret_val;
SELECT test_option_and_default(100) AS combo_default;
SELECT test_option_and_default(100, 'Pgxcrown') AS combo_override;
