-- PostgreSQL C parser AST introspection regression suite (PG 14-17 compatible)
SELECT pg_ast_query_type() AS def_query_type;
SELECT pg_ast_query_type('SELECT id FROM users') AS sel_type;
SELECT pg_ast_query_type('INSERT INTO users (name) VALUES (''Alice'')') AS ins_type;
SELECT pg_ast_query_type('UPDATE users SET active = true') AS upd_type;
SELECT pg_ast_query_type('DELETE FROM users WHERE id = 1') AS del_type;
SELECT pg_ast_query_type('DROP TABLE audit_logs') AS drop_type;
SELECT pg_ast_query_type('CREATE TABLE audit_logs (id int)') AS create_type;
SELECT pg_ast_to_raw(NULL) IS NULL AS raw_null_safe;
SELECT pg_ast_to_raw('CREATE TABLE audit_logs (id int)') ILIKE '%CREATESTMT%' AS raw_has_createstmt;
SELECT pg_ast_to_json(NULL) IS NULL AS json_null_safe;
SELECT
  (j::jsonb)->>'status' AS status,
  (j::jsonb)->>'raw_sql' AS raw_sql,
  ((j::jsonb)->>'ast_tree') ILIKE '%CREATESTMT%' AS json_has_createstmt
FROM (SELECT pg_ast_to_json('CREATE TABLE audit_logs (id int)') AS j) t;
