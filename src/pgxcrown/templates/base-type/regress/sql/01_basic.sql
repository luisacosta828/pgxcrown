CREATE FUNCTION pg_temp.check_invalid_{{type_name}}(raw text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM raw::{{type_name}};
  RETURN 'UNEXPECTED_OK';
EXCEPTION WHEN invalid_parameter_value THEN
  RETURN 'REJECTED_22023';
END $$;

SELECT '  ab-42  '::{{type_name}} AS parsed_code;
SELECT {{project_snake}}_prefix('pgx-99'::{{type_name}}) AS code_prefix;
SELECT {{project_snake}}_opt_prefix(NULL::{{type_name}}) IS NULL AS null_prefix_is_null;
SELECT pg_temp.check_invalid_{{type_name}}('   ') AS empty_rejected;

CREATE TABLE {{project_snake}}_items (
  id int4 PRIMARY KEY,
  code {{type_name}}
);

INSERT INTO {{project_snake}}_items VALUES
  (1, '  ab-42  '),
  (2, 'pgx-99'),
  (3, NULL);

SELECT id,
       code,
       {{project_snake}}_opt_prefix(code) AS opt_prefix,
       {{project_snake}}_coalesce_code(code, 'dflt-0'::{{type_name}}) AS effective_code
FROM {{project_snake}}_items
ORDER BY id;
