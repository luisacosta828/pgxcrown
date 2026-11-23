# Ejemplo 07 — Extensión Multi-Módulo, Procedimientos SQL y Snapshots/Migraciones

Este ejemplo demuestra cómo estructurar una extensión real de PostgreSQL en **múltiples módulos Nim**, exponer procedimientos SQL (`CALL`), aplicar hardening de privilegios (`SECURITY DEFINER`, `search_path`, `LEAKPROOF`) y gestionar el ciclo de vida de versiones (`0.1.0` → `0.2.0`) mediante snapshots automáticos y migraciones incrementales.

## Qué demuestra

1. **Arquitectura multi-módulo** (`src/main.nim` + `src/billing_ops.nim`):
   - `pgxcrown` recorre topológicamente los módulos locales importados y genera un único `.so` y un único script SQL unificado.
   - Ambos módulos definen `{.pgxInit.}`, ejecutándose en orden determinista dentro de `_PG_init` (submódulos primero, `main.nim` después).
   - Las funciones auxiliares internas marcadas con `{.noSql.}` (`computeCentsInternal`) no se exportan al catálogo `pg_proc`.
2. **Metadata declarativa (`pgxext.json` + `pgxExtension:`)**:
   - `pgxext.json` provee la configuración base (`"version": "0.1.0"`, `"relocatable"`, `"trusted"`).
   - El bloque `pgxExtension:` en `src/main.nim` tiene prioridad y sobrescribe los campos en el archivo `.control` generado (por ejemplo `trusted = true`).
3. **Procedimientos SQL (`PROCEDURE`)**:
   - Todo `proc` exportado en Nim sin tipo de retorno (o con `: void`) se compila como `CREATE OR REPLACE PROCEDURE ... LANGUAGE c`, invocable mediante `CALL ex07_post_charge(1500);`.
4. **Hardening de funciones**:
   - `{.securityDefiner, searchPath: "public, pg_catalog".}` fija `SECURITY DEFINER` y `SET search_path = public, pg_catalog` para prevenir ataques de shadowing de esquema.
   - `{.securityInvoker.}` mantiene los permisos del invocador.
   - `{.leakproof.}` marca funciones puras (`ex07_is_valid_amount`) como seguras para pushdown en vistas `security_barrier` y políticas RLS.

## Estructura de archivos

```text
07_multimodule_and_procedures/
├── pgxext.json                 # Metadata base (version, relocatable, trusted)
├── README.md
├── src/
│   ├── main.nim                # Punto de entrada, pgxExtension:, pgxInit, ex07_reset_ledger
│   └── billing_ops.nim         # Submódulo con pgxInit, PROCEDURE, securityDefiner y leakproof
└── tests/
    ├── sql/01_demo.sql         # Suite de regresión SQL
    └── expected/01_demo.out    # Salida dorada esperada
```

## Cómo compilar, verificar y probar

```bash
# 1. Compilar la extensión (.so, .control, .sql, .integrity.json)
pgxtool build-extension examples/07_multimodule_and_procedures

# 2. Verificar integridad y auditoría ELF/Security v2
pgxtool verify examples/07_multimodule_and_procedures

# 3. Ejecutar pruebas de regresión en Docker (PG 18 o todas PG 14–18)
pgxtool test examples/07_multimodule_and_procedures --pg 18
pgxtool test examples/07_multimodule_and_procedures --all
```

## Instalación y prueba manual en `psql`

> Nota: Como el nombre del directorio inicia con dígitos (`07_...`), en SQL debes **comillar el nombre de la extensión** (`"07_multimodule_and_procedures"`).

```bash
pgxtool build-extension examples/07_multimodule_and_procedures
sudo ./examples/07_multimodule_and_procedures/src/install.sh
```

```sql
CREATE EXTENSION "07_multimodule_and_procedures";

SELECT ex07_init_status();
SELECT ex07_is_valid_amount(500);
SELECT ex07_calc_invoice(4, 250);

CALL ex07_reset_ledger();
CALL ex07_post_charge(1500);
SELECT ex07_ledger_total();
```

---

## Snapshots de Esquema y Migraciones Incrementales (`0.1.0` → `0.2.0`)

`pgxcrown` incluye un motor automático de **snapshots estructurados** y generación de scripts de actualización para `ALTER EXTENSION ... UPDATE`:

1. **Captura en la versión `0.1.0`**:
   Al ejecutar `pgxtool build-extension` con `version = "0.1.0"`, `pgx.nim` guarda dentro de `.pgx_build/`:
   - `.pgx_build/schema_0.1.0.json`: snapshot JSON estructurado (tipos base, enums, compuestos, firmas de funciones/procedimientos y bloques `pgxSql`).
   - `.pgx_build/sql_snapshots/07_multimodule_and_procedures--0.1.0.sql`: script base exacto de la `0.1.0`.
   - `.pgx_build/last_version.txt`: registra `"0.1.0"`.

2. **Evolución a `0.2.0`**:
   Cuando cambias `version = "0.2.0"` (en `pgxExtension:` / `pgxext.json`), agregas una nueva función o valor de enum, y vuelves a ejecutar `pgxtool build-extension`:
   - `pgx.nim` detecta el cambio `0.1.0 -> 0.2.0`, compara `schema_0.1.0.json` contra el nuevo AST y genera automáticamente en `migrations/`:
     - `migrations/07_multimodule_and_procedures--0.1.0.sql` (preservando la línea base instalable de `0.1.0`)
     - `migrations/07_multimodule_and_procedures--0.1.0--0.2.0.sql` (conteniendo `ALTER TYPE ... ADD VALUE IF NOT EXISTS`, `ALTER TYPE ... ADD ATTRIBUTE`, `CREATE OR REPLACE FUNCTION/PROCEDURE`, etc.)
   - Si el archivo `migrations/<ext>--0.1.0--0.2.0.sql` ya existe y lo editaste manualmente, `pgx.nim` **nunca lo sobrescribe**.

3. **Instalación y actualización en PostgreSQL**:
   Tanto `install.sh` como `pgxtool test` copian `migrations/<ext>--*.sql` al directorio `extension/` de PostgreSQL, permitiéndote probar el upgrade real en SQL:
   ```sql
   CREATE EXTENSION "07_multimodule_and_procedures" VERSION '0.1.0';
   ALTER EXTENSION "07_multimodule_and_procedures" UPDATE TO '0.2.0';
   ```
