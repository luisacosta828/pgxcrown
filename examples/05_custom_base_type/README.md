# Ejemplo 05: Tipo SQL base propio (`{.pgxType: string.}`), operadores e índice B-tree

## Qué demuestra el ejemplo

Este ejemplo construye un tipo de dato nativo de PostgreSQL (`ex05_iban`) de principio a fin con validación estricta en Nim e indexación B-tree real:

- **Tipo base declarativo (`{.pgxType: string.}`)**: `ex05_iban` genera el *shell type*, las funciones `INPUT`/`OUTPUT` (`parse_ex05_iban`, `format_ex05_iban`) y `CREATE TYPE "ex05_iban" (... LIKE = text)`.
- **Validación en parser (`22023`)**: `parse_ex05_iban` normaliza espacios y mayúsculas, verifica la estructura IBAN y valida el dígito de control ISO 7064 Mod-97-10. Cualquier entrada inválida lanza `ValueError` (`SQLSTATE 22023`).
- **Operadores e índice B-tree con `pgxSql(..., phase = "post")`**:
  - Define los operadores `<`, `<=`, `=`, `<>`, `>=`, `>` y la función de comparación `ex05_iban_cmp`.
  - Registra `CREATE OPERATOR CLASS ex05_iban_ops DEFAULT FOR TYPE ex05_iban USING btree`.
  - Crea la tabla real `ex05_ledger` y el índice `idx_ex05_ledger_iban` usando B-tree, permitiendo filtros `WHERE` y ordenación `ORDER BY` nativas.
- **Seguridad (`"trusted": false`)**: en PostgreSQL, crear operadores y clases de operadores requiere privilegios de superusuario, por eso `pgxext.json` declara `"trusted": false` y `"relocatable": true` sin asumir rutas o esquemas fijos.

## Estructura de archivos

```text
05_custom_base_type/
├── pgxext.json                # Metadatos (.control) con trusted: false
├── src/
│   └── main.nim               # Tipo ex05_iban, parser Mod-97, operadores y pgxSql B-tree
├── tests/
│   ├── sql/
│   │   └── 01_demo.sql        # Validacion, operadores, WHERE/ORDER BY e indice B-tree
│   └── expected/
│       └── 01_demo.out        # Salida esperada exacta de psql
└── README.md
```

## Cómo crearlo desde cero

### Opción A: usando la plantilla `base-type` con `pgxtool new`

```bash
pgxtool new ./05_custom_base_type --template base-type --var type_name=ex05_iban
```

Después cambia `"trusted": false` en `pgxext.json` y agrega en `src/main.nim` las funciones de comparación, la clase de operador B-tree y la tabla `ex05_ledger` mediante `pgxSql(..., phase = "post")`.

### Opción B: paso a paso manualmente

```bash
mkdir -p 05_custom_base_type/src 05_custom_base_type/tests/sql 05_custom_base_type/tests/expected
```

1. Configura `pgxext.json` con `"version": "0.1.0"`, `"relocatable": true` y `"trusted": false`.
2. Define `ex05_iban* {.pgxType: string.} = distinct string`, `parse_ex05_iban` (`{.pgxInput.}`), `format_ex05_iban` (`{.pgxOutput.}`), los comparadores y el bloque `pgxSql(..., phase = "post")`.
3. Añade las pruebas en `tests/sql/01_demo.sql` y `tests/expected/01_demo.out`.

## Cómo compilarlo

```bash
pgxtool build-extension examples/05_custom_base_type
```

## Cómo verificar seguridad e integridad

```bash
pgxtool verify examples/05_custom_base_type
```

## Cómo ejecutar pruebas

Para probar en PostgreSQL 18 dentro de Docker:

```bash
pgxtool test examples/05_custom_base_type --pg 18
```

Para validar todas las versiones soportadas (PostgreSQL 14 a 18):

```bash
pgxtool test examples/05_custom_base_type --all
```

## Cómo instalarlo y probarlo manualmente en `psql`

```bash
sudo examples/05_custom_base_type/src/install.sh
```

Conéctate como superusuario en `psql` (requerido porque `"trusted": false`):

```sql
CREATE EXTENSION "05_custom_base_type";

SELECT '  de89 3704 0044 0532 0130 00  '::ex05_iban;
SELECT ex05_iban_masked('es91 2100 0418 4502 0005 1332'::ex05_iban);

INSERT INTO ex05_ledger (id, iban, holder, balance_cents) VALUES
  (1, 'de89 3704 0044 0532 0130 00', 'Berlin Ops', 125000),
  (2, 'es91 2100 0418 4502 0005 1332', 'Madrid Retail', 280000);

SELECT id, iban, holder FROM ex05_ledger ORDER BY iban;

DROP EXTENSION "05_custom_base_type";
```
