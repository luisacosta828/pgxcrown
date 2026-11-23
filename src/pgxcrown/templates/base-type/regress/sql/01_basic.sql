SELECT '  ab-42  '::{{type_name}} AS parsed_code;
SELECT {{project_snake}}_prefix('pgx-99'::{{type_name}}) AS code_prefix;
