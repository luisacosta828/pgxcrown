SELECT {{project_snake}}_hello() LIKE 'Hello, World from %!' AS default_greeting_ok;
SELECT {{project_snake}}_hello('PostgreSQL') LIKE 'Hello, PostgreSQL from %!' AS custom_greeting_ok;
SELECT {{project_snake}}_add(19, 23) AS sum_42;
SELECT {{project_snake}}_slugify('  Hello Pgxcrown  ') AS slugified_text;
