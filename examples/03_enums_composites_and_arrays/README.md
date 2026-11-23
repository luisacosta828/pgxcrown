# Ejemplo 03: Enums `{.pure.}`, tipos compuestos y arrays (`seq[T]` y `PgVector[T]`)

## Qué demuestra el ejemplo

Este ejemplo muestra cómo modelar tipos ricos estructurados entre Nim y PostgreSQL sin escribir SQL manual:

- **Enums `{.pure.}`**: `ex03_order_state` con etiquetas explícitas (`'pending'`, `'confirmed'`, `'shipped'`) genera `CREATE TYPE "ex03_order_state" AS ENUM (...)`.
- **Tipos compuestos (`object`)**: `ex03_line_item` genera `CREATE TYPE "ex03_line_item" AS (...)` reutilizando el enum `ex03_order_state`, y puede enviarse y devolverse tanto en escalares (`ex03_make_item`, `ex03_item_total_cents`) como en arreglos (`seq[ex03_line_item]` -> `ex03_line_item[]`) y conjuntos (`SETOF ex03_line_item` en `ex03_build_order`).
- **Arrays nativos y zero-copy**:
  - `seq[int32]` y `seq[string]` como parámetros (`int4[]`, `text[]`).
  - `PgVector[int32]` (`ex03_scale_vector`) para lectura *zero-copy* sobre arreglos de PostgreSQL y retorno directo como `int4[]`.

## Estructura de archivos

```text
03_enums_composites_and_arrays/
├── pgxext.json                # Metadatos de la extensión (.control)
├── src/
│   └── main.nim               # Enum, composite object y UDFs con seq[T]/PgVector[T]
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Pruebas SQL de enum, composite, composite[] y arrays
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `starter-udf` con `pgxtool new`

```bash
pgxtool new ./03_enums_composites_and_arrays --template starter-udf
```

Luego define el `enum` `{.pure.}`, el `object` compuesto y las funciones `ex03_*` en `src/main.nim`.

### Opción B: paso a paso manualmente

```bash
mkdir -p 03_enums_composites_and_arrays/src 03_enums_composites_and_arrays/tests/sql 03_enums_composites_and_arrays/tests/expected
```

1. Configura `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": true`.
2. Exporta `ex03_order_state* {.pure.}` y `ex03_line_item* = object` en `src/main.nim` junto con sus procs `*`.
3. Escribe `tests/sql/01_demo.sql` y `tests/expected/01_demo.out`.

## Cómo compilarlo

```bash
pgxtool build-extension examples/03_enums_composites_and_arrays
```

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/03_enums_composites_and_arrays
```

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/03_enums_composites_and_arrays --pg 18
```

Para validar todas las versiones soportadas (PostgreSQL 14 a 18):

```bash
pgxtool test examples/03_enums_composites_and_arrays --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/03_enums_composites_and_arrays/src/install.sh
```

En `psql`:

```sql
CREATE EXTENSION "03_enums_composites_and_arrays";

SELECT ex03_next_state('pending'::ex03_order_state);
SELECT (ex03_make_item('sku-101', 3, 450)).*;
SELECT ex03_sum_order_cents(ARRAY[
  ROW('SKU-A', 2, 500, 'pending')::ex03_line_item,
  ROW('SKU-B', 5, 300, 'confirmed')::ex03_line_item
]);
SELECT * FROM ex03_build_order(ARRAY['kbd-01', 'mouse-02'], ARRAY[2, 0], 1990);
SELECT ex03_scale_vector(ARRAY[2, -3, 5]::int4[], 10);

DROP EXTENSION "03_enums_composites_and_arrays";
```
