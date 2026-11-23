# Ejemplo 06: Iteradores SRF en streaming `O(1)`

## Qué demuestra el ejemplo

Este ejemplo muestra cómo implementar *Set-Returning Functions* (`RETURNS SETOF ...`) mediante `iterator` de Nim en memoria constante `O(1)` por fila:

- **Sobrecarga de iteradores (`SETOF int64`)**: `ex06_stream_range(n)` y `ex06_stream_range(startVal, endVal)` comparten nombre SQL con símbolos C mangling distintos.
- **Streaming `O(1)` y corte temprano (`LIMIT`)**: `ex06_stream_range(50000)` y `ex06_stream_range(1000000) LIMIT 3` generan valores fila a fila sin materializar listas de millones de elementos en memoria.
- **Emisión de `SQL NULL` (`Option[string]`)**: `ex06_stream_nullable` produce `NULL` reales en SQL cada vez que emite `none(string)`.
- **Registros compuestos en streaming (`SETOF ex06_event_row`)**: `ex06_stream_events` retorna columnas tipadas directamente desde un `object` de Nim.
- **Limpieza garantizada con ARC (`=destroy`) y Panic Shield**: `ex06_stream_guarded` usa un guardia RAII con `=destroy` conectado al callback de reset de `multi_call_memory_ctx`, asegurando la liberación determinista tanto al completar el stream como al abortar con `LIMIT` o tras un error a mitad del flujo.

## Estructura de archivos

```text
06_streaming_srf_iterators/
├── pgxext.json                # Metadatos de la extensión (.control)
├── src/
│   └── main.nim               # Iteradores sobrecargados, Option[string], composite y RAII
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Pruebas de streaming 50k, LIMIT, NULL, composite y error
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `starter-udf` con `pgxtool new`

```bash
pgxtool new ./06_streaming_srf_iterators --template starter-udf
```

Luego sustituye el contenido de `src/main.nim` por los `iterator` exportados con `*` y el tipo `ex06_event_row*`.

### Opción B: paso a paso manualmente

```bash
mkdir -p 06_streaming_srf_iterators/src 06_streaming_srf_iterators/tests/sql 06_streaming_srf_iterators/tests/expected
```

1. Configura `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": true`.
2. Implementa los `iterator` exportados con `*` en `src/main.nim` (para `int64`, `Option[string]`, `ex06_event_row` y limpieza con RAII).
3. Añade `tests/sql/01_demo.sql` y `tests/expected/01_demo.out`.

## Cómo compilarlo

```bash
pgxtool build-extension examples/06_streaming_srf_iterators
```

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/06_streaming_srf_iterators
```

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/06_streaming_srf_iterators --pg 18
```

Para validar todas las versiones soportadas (PostgreSQL 14 a 18):

```bash
pgxtool test examples/06_streaming_srf_iterators --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/06_streaming_srf_iterators/src/install.sh
```

En `psql`:

```sql
CREATE EXTENSION "06_streaming_srf_iterators";

SELECT * FROM ex06_stream_range(5);
SELECT * FROM ex06_stream_range(10, 14);
SELECT * FROM ex06_stream_nullable('row', 4);
SELECT seq_no, label, is_even FROM ex06_stream_events(4);
SELECT * FROM ex06_stream_guarded(1000, 0) LIMIT 2;
SELECT ex06_cleanup_count();

DROP EXTENSION "06_streaming_srf_iterators";
```
