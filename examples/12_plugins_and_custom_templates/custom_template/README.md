# {{project_name}}

Extension generated with `pgxcrown` v{{pgxcrown_version}} from the `ex12-custom-service` custom template (`service_tag={{service_tag}}`).

## Building, Verifying, and Testing

```bash
pgxtool build-extension .
pgxtool verify .
pgxtool test . --all
```

## Usage in `psql`

```sql
CREATE EXTENSION {{project_name}};

SELECT {{project_snake}}_tag();
SELECT {{project_snake}}_log('initial_event');
SELECT * FROM {{project_snake}}_events ORDER BY id;
```
