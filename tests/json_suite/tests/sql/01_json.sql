-- JSON & JSONB serialization, Option[JsonNode], defaults, and SETOF regression suite
SELECT json_enrich('{"app": "pgxcrown"}'::jsonb) AS enriched;
SELECT json_get_str('{"name": "nim", "version": "2.4"}'::jsonb, 'name') AS extracted;
SELECT json_get_str('{"name": "nim"}'::jsonb, 'missing') AS missing_key;
SELECT json_safe_transform(NULL) IS NULL AS transform_null;
SELECT json_safe_transform('{"step": 1}'::jsonb) AS transform_some;
SELECT json_with_defaults() AS def_json;
SELECT json_with_defaults('{"mode": "custom", "active": false}'::jsonb) AS custom_json;
SELECT item FROM json_extract_items('[10, 20, "hi"]'::jsonb) AS item;
SELECT item FROM json_extract_items('{"a": 1, "b": "two"}'::jsonb) AS item;
