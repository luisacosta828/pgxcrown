# Ejemplo 08 — `QueryBuilder` Fluent y SPI Binario v2

Este ejemplo muestra la capa **SPI Binario v2** junto al **`QueryBuilder` tipado** de `pgxcrown`: ejecución parametrizada (`$1`, `$2`, ...), deserialización binaria directa hacia `object` de Nim (`fetch[Row]`), distinción estricta entre SQL `NULL` y cadena vacía `""` mediante `Option[string]`, planes preparados persistentes (`spiPrepare(..., keep = true)`) y lectura en streaming mediante cursores (`spiCursorOpen` / `spiCursorFetch` / `spiCursorClose` y `stream[Row]`).

## Qué demuestra

1. **`QueryBuilder` parametrizado e inmune a SQLi**:
   - `InsertInto(...).Values(...).Returning("id").scalar(int32)` y `Update(...).Set(...).Where(...).Returning(...)` pasan parámetros binarios tipados (`$1`, `$2`, ...), protegiendo contra payloads como `'; DROP TABLE ...; --`.
2. **Deserialización binaria tipada (`fetch[Row]`)**:
   - Decodifica directamente los `Datum` de PostgreSQL hacia `Ex08OrderRow` / `Ex08ItemRow` sin conversiones de texto intermedias.
3. **`Option[string]`: SQL `NULL` vs string vacío `""`**:
   - `none(string)` representa SQL `NULL`, mientras `some("")` preserva la cadena vacía `""` sin colapsarlos.
4. **Planes preparados persistentes (`SpiPlan`)**:
   - `spiPrepare(..., [TEXTOID], keep = true)` mantiene el plan compilado en memoria de PostgreSQL (`SPI_keepplan`) entre llamadas y lo ejecuta con `fetchPlan[Row](plan, [toBoundParam(sku)])`.
5. **Cursores streaming (`SpiCursor` y `stream[Row]`)**:
   - `spiCursorOpen` / `spiCursorFetch` / `spiCursorClose` y el iterador `stream[Row](q, batchSize)` procesan lotes acotados en memoria `O(batchSize)` y cierran los portales limpiamente (`pg_cursors = 0`).

## Estructura de archivos

```text
08_query_builder_and_binary_spi/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Cómo compilar, verificar y probar

```bash
pgxtool build-extension examples/08_query_builder_and_binary_spi
pgxtool verify examples/08_query_builder_and_binary_spi
pgxtool test examples/08_query_builder_and_binary_spi --pg 18
pgxtool test examples/08_query_builder_and_binary_spi --all
```

## Instalación y prueba manual en `psql`

```bash
pgxtool build-extension examples/08_query_builder_and_binary_spi
sudo ./examples/08_query_builder_and_binary_spi/src/install.sh
```

```sql
CREATE EXTENSION "08_query_builder_and_binary_spi";

CREATE TABLE ex08_orders (id serial PRIMARY KEY, code text NOT NULL, note text, amount bigint NOT NULL);
CREATE TABLE ex08_items (id serial PRIMARY KEY, sku text NOT NULL, qty int4 NOT NULL);
INSERT INTO ex08_items (sku, qty) VALUES ('CPU-01', 4), ('CPU-01', 6);

SELECT ex08_insert_order('ORD-EMPTY', '', 100);
SELECT ex08_insert_order('ORD-NULL', NULL, 200);
SELECT ex08_inspect_orders(0);

SELECT ex08_prepare_sku_plan();
SELECT ex08_lookup_sku('CPU-01');
SELECT ex08_stream_summary(4, 2);
```
