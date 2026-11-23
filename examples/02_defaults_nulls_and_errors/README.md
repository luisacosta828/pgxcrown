# Ejemplo 02: Parámetros DEFAULT, manejo seguro de NULL y Panic Shield

## Qué demuestra el ejemplo

Este ejemplo muestra cómo diseñar UDFs robustas frente a valores omitidos, `NULL` y fallos en tiempo de ejecución sin poner en riesgo el proceso de PostgreSQL:

- **Parámetros `DEFAULT`**: `ex02_greet_default` y `ex02_safe_divide` traducen valores por defecto de Nim directamente a cláusulas `DEFAULT` en el DDL SQL.
- **`Option[T]` bidireccional**: `ex02_safe_divide` acepta `Option[int32]` y devuelve `Option[int32]`; al retornar `none(int32)` emite SQL `NULL` de forma segura.
- **`{.calledOnNullInput.}`**: `ex02_coalesce_label` desactiva `STRICT` (`proisstrict = f`) para ejecutar la lógica Nim incluso cuando se pasa `NULL`.
- **Errores controlados (`SQLSTATE`)**:
  - `raise newException(ValueError, ...)` en `ex02_validate_port` se traduce a SQLSTATE `22023` (`invalid_parameter_value`).
  - `raisePgError("22023", ...)` y `raisePgError("22012", ...)` emiten errores nativos de PostgreSQL con `hint` y `SQLSTATE` exacto.
- **Panic Shield (`Defect` -> `ereport(ERROR)`)**: `ex02_checked_add` (`OverflowDefect` -> `22003`) y `ex02_pick_item` (`IndexDefect` -> `2202E`) demuestran que Nim intercepta los *defects* antes de hacer *abort* y permite que el backend continúe operando normalmente.

## Estructura de archivos

```text
02_defaults_nulls_and_errors/
├── pgxext.json                # Metadatos de la extensión (.control)
├── src/
│   └── main.nim               # UDFs con defaults, Option[T], calledOnNullInput y errores
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Pruebas deterministas con wrappers pg_temp y VERBOSITY terse
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `starter-udf` con `pgxtool new`

```bash
pgxtool new ./02_defaults_nulls_and_errors --template starter-udf
```

Luego importa `std/options` en `src/main.nim` y define las funciones `ex02_*` con `Option[T]`, `{.calledOnNullInput.}` y `raisePgError`.

### Opción B: paso a paso manualmente

```bash
mkdir -p 02_defaults_nulls_and_errors/src 02_defaults_nulls_and_errors/tests/sql 02_defaults_nulls_and_errors/tests/expected
```

1. Configura `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": true`.
2. Implementa `src/main.nim` usando `std/options`, `{.calledOnNullInput.}`, `raise newException(ValueError, ...)` y `raisePgError`.
3. Añade `tests/sql/01_demo.sql` con `\set VERBOSITY terse` y wrappers `pg_temp.` para verificar cada `SQLSTATE` de forma determinista.

## Cómo compilarlo

```bash
pgxtool build-extension examples/02_defaults_nulls_and_errors
```

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/02_defaults_nulls_and_errors
```

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/02_defaults_nulls_and_errors --pg 18
```

Para validar todas las versiones soportadas (PostgreSQL 14 a 18):

```bash
pgxtool test examples/02_defaults_nulls_and_errors --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/02_defaults_nulls_and_errors/src/install.sh
```

En `psql` (entrecomillando el nombre porque comienza con dígitos):

```sql
CREATE EXTENSION "02_defaults_nulls_and_errors";

SELECT ex02_greet_default();
SELECT ex02_safe_divide(42, NULL) IS NULL;
SELECT ex02_safe_divide(42, 6);
SELECT ex02_coalesce_label(NULL, 'invitado');
SELECT ex02_validate_port(5432);

-- Provocar un error controlado o OverflowDefect (no tumba la sesion):
-- SELECT ex02_validate_port(70000);
-- SELECT ex02_checked_add(2147483647, 1);

DROP EXTENSION "02_defaults_nulls_and_errors";
```
