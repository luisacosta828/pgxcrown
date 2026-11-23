# Ejemplo 01: UDFs escalares básicas, volatilidad y paralelismo

## Qué demuestra el ejemplo

Este primer ejemplo muestra cómo escribir funciones escalares de PostgreSQL en Nim usando `pgxcrown`:

- **Exportación automática a SQL**: todo `proc` exportado con `*` genera su sentencia `CREATE OR REPLACE FUNCTION` y el código C de interfaz PG V1.
- **Atributos de volatilidad**:
  - `{.immutable.}` (`ex01_greet`, `ex01_add`, `ex01_slugify`): garantiza ausencia de efectos secundarios (`noSideEffect`, `provolatile = 'i'`).
  - `{.stable.}` (`ex01_discount`): permite lecturas consistentes dentro de una sentencia (`provolatile = 's'`).
  - `{.volatile.}` (`ex01_next_seq`): mantiene estado mutable en memoria de backend (`provolatile = 'v'`).
- **Seguridad en ejecución paralela**: `{.parallelSafe.}` marca las funciones puras con `PARALLEL SAFE` (`proparallel = 's'`) para que el planificador pueda ejecutarlas en *parallel workers*.
- **Verificación en catálogo**: las pruebas consultan `pg_proc` para comprobar `provolatile`, `proparallel` y `proisstrict`.

## Estructura de archivos

```text
01_hello_scalar_udf/
├── pgxext.json                # Metadatos de la extensión (.control)
├── src/
│   └── main.nim               # Implementación Nim de las UDFs escalares
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Script SQL de demostración y regresión
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `starter-udf` con `pgxtool new`

```bash
pgxtool new ./01_hello_scalar_udf --template starter-udf
```

Después sustituye el contenido de `pgxext.json`, `src/main.nim` y `tests/sql/01_demo.sql` por las funciones `ex01_*` de este ejemplo.

### Opción B: paso a paso manualmente

```bash
mkdir -p 01_hello_scalar_udf/src 01_hello_scalar_udf/tests/sql 01_hello_scalar_udf/tests/expected
```

1. Crea `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": true`.
2. Escribe `src/main.nim` importando `pgxcrown` y exportando con `*` los `proc` decorados con `{.immutable, parallelSafe.}`, `{.stable.}` y `{.volatile.}`.
3. Agrega las consultas en `tests/sql/01_demo.sql` y su salida esperada en `tests/expected/01_demo.out`.

## Cómo compilarlo

```bash
pgxtool build-extension examples/01_hello_scalar_udf
```

Esto compila la librería compartida (`src/01_hello_scalar_udf.so`), genera el archivo `.control`, el script SQL de instalación y el manifiesto de integridad `.integrity.json`.

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/01_hello_scalar_udf
```

Ejecuta la auditoría de símbolos ELF prohibidos, dependencias compartidas e integridad SHA-256 del paquete compilado.

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/01_hello_scalar_udf --pg 18
```

Para validar la matriz completa de PostgreSQL 14 a 18:

```bash
pgxtool test examples/01_hello_scalar_udf --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/01_hello_scalar_udf/src/install.sh
```

Luego abre `psql` y recuerda **entrecomillar el nombre de la extensión** porque comienza con dígitos:

```sql
CREATE EXTENSION "01_hello_scalar_udf";

SELECT ex01_greet('PostgreSQL');
SELECT ex01_add(19, 23);
SELECT ex01_slugify('  Hola   Pgxcrown   2026  ');
SELECT ex01_discount(120.0, 25.0);
SELECT ex01_next_seq(), ex01_next_seq();

SELECT proname, provolatile, proparallel, proisstrict
FROM pg_proc
WHERE proname IN ('ex01_greet', 'ex01_add', 'ex01_slugify', 'ex01_discount', 'ex01_next_seq')
ORDER BY proname;

DROP EXTENSION "01_hello_scalar_udf";
```
