SELECT {{project_snake}}_tag() = '{{service_tag}}' AS tag_matches;
SELECT {{project_snake}}_log('boot') = 1 AS first_id_ok;
SELECT {{project_snake}}_log('ready') = 2 AS second_id_ok;
SELECT count(*) = 2 AS two_rows_logged,
       bool_and(service_tag = '{{service_tag}}') AS all_tags_match
FROM {{project_snake}}_events;
