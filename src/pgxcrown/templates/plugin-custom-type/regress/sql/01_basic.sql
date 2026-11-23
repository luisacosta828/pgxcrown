SELECT {{project_snake}}_plugin_ready() AS plugin_ready;
SELECT {{project_snake}}_plugin_meta('  ALPHA  '::{{type_name}}) = 'type={{type_name}}|roundtrip=alpha|param=''alpha''' AS meta_ok;
SELECT {{project_snake}}_audit_insert('alpha'::{{type_name}}) AS inserted_rows;
SELECT tag AS audit_tag FROM {{project_snake}}_audit ORDER BY id;
