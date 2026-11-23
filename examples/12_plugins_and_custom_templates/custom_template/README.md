# {{project_name}}

Extensión generada con `pgxcrown` v{{pgxcrown_version}} desde el template personalizado `ex12-custom-service` (`service_tag={{service_tag}}`).

## Compilación, verificación y pruebas

```bash
pgxtool build-extension .
pgxtool verify .
pgxtool test . --all
```

## Uso en `psql`

```sql
CREATE EXTENSION {{project_name}};

SELECT {{project_snake}}_tag();
SELECT {{project_snake}}_log('evento_inicial');
SELECT * FROM {{project_snake}}_events ORDER BY id;
```
