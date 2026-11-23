# Ejemplo 04: Tipos ricos de PostgreSQL (`JSONB`, `UUID`, `BYTEA`, `NUMERIC` y temporales)

## Qué demuestra el ejemplo

Este ejemplo muestra cómo operar directamente sobre los tipos nativos avanzados de PostgreSQL sin conversiones manuales propensas a errores ni pérdida de precisión:

- **`JsonNode` (`jsonb`)**: lectura, mutación sobre copia (`payload.copy()`) y retorno seguro de documentos `jsonb` (`ex04_json_tag`, `ex04_json_get`).
- **`PgUuid` (`uuid`)**: inspección de versión RFC 4122/9562 y variante sobre los 16 bytes nativos (`ex04_uuid_info`).
- **`PgBytea` (`bytea`)**: lectura binaria *zero-copy* segura ante bytes `0x00` (`NUL`) y retorno de nuevos buffers (`ex04_bytea_stats`, `ex04_bytea_xor`).
- **`PgNumeric` (`numeric`)**: aritmética exacta de precisión arbitraria delegada al kernel de PostgreSQL (`ex04_numeric_total`).
- **Temporales (`PgDate`, `PgTimestamp`, `PgTimestampTz`, `PgInterval`)**: interoperabilidad directa con épocas de PostgreSQL, años bisiestos, valores `infinity` y `std/times` (`ex04_date_shift`, `ex04_ts_add_seconds`, `ex04_tstz_norm_utc`, `ex04_interval_add_us`).

## Estructura de archivos

```text
04_rich_datatypes_and_jsonb/
├── pgxext.json                # Metadatos de la extensión (.control)
├── src/
│   └── main.nim               # UDFs con JsonNode, PgUuid, PgBytea, PgNumeric y temporales
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Pruebas deterministas fijando UTC, ISO, MDY e intervalstyle
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `starter-udf` con `pgxtool new`

```bash
pgxtool new ./04_rich_datatypes_and_jsonb --template starter-udf
```

Después agrega `std/[json, options, strutils, times]` y las funciones `ex04_*` en `src/main.nim`.

### Opción B: paso a paso manualmente

```bash
mkdir -p 04_rich_datatypes_and_jsonb/src 04_rich_datatypes_and_jsonb/tests/sql 04_rich_datatypes_and_jsonb/tests/expected
```

1. Configura `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": true`.
2. Implementa las UDFs en `src/main.nim` usando `JsonNode`, `PgUuid`, `PgBytea`, `PgNumeric`, `PgDate`, `PgTimestamp`, `PgTimestampTz` y `PgInterval`.
3. Fija `SET timezone = 'UTC'; SET datestyle = 'ISO, MDY'; SET intervalstyle = 'postgres';` al principio de `tests/sql/01_demo.sql` para garantizar reproducibilidad entre PostgreSQL 14 y 18.

## Cómo compilarlo

```bash
pgxtool build-extension examples/04_rich_datatypes_and_jsonb
```

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/04_rich_datatypes_and_jsonb
```

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/04_rich_datatypes_and_jsonb --pg 18
```

Para validar todas las versiones soportadas (PostgreSQL 14 a 18):

```bash
pgxtool test examples/04_rich_datatypes_and_jsonb --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/04_rich_datatypes_and_jsonb/src/install.sh
```

En `psql`:

```sql
CREATE EXTENSION "04_rich_datatypes_and_jsonb";

SET timezone = 'UTC';
SELECT ex04_json_tag('{"app": "pgxcrown"}'::jsonb, 'audited');
SELECT ex04_uuid_info('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid);
SELECT ex04_bytea_stats('\x004100ff00'::bytea);
SELECT ex04_numeric_total(19.995::numeric, 3::numeric, 0.0825::numeric);
SELECT ex04_tstz_norm_utc('2024-02-29 14:30:00.5+02:00'::timestamptz);

DROP EXTENSION "04_rich_datatypes_and_jsonb";
```
