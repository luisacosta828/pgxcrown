# Ejemplos Progresivos de Pgxcrown (01 → 12)

Guía de aprendizaje progresivo para construir, auditar y probar extensiones de **PostgreSQL 14–18** con **Pgxcrown (Nim + C)**, desde UDFs escalares básicos hasta servicios seguros con GUCs RBAC, hooks componibles, memoria compartida, Background Workers y extensibilidad mediante plugins y plantillas.

---

## Ruta de Aprendizaje Progresiva (01 → 12)

| # | Ejemplo | Nivel | Features principales que cubre | ¿Requiere `shared_preload_libraries`? |
|:-:|:--------|:-----:|:-------------------------------|:-------------------------------------:|
| **01** | Serie 01 (`examples/01_*`) | Básico | Primeros pasos: UDFs escalares tipados, pragmas `immutable` / `parallelSafe`, `pgxext.json` y pruebas `pg_regress` | No |
| **02** | Serie 02 (`examples/02_*`) | Básico | Manejo de `NULL`, valores `DEFAULT`, `Option[T]` (`CALLED ON NULL INPUT` vs `STRICT`) y validación con `raisePgError` | No |
| **03** | Serie 03 (`examples/03_*`) | Intermedio | Tipos compuestos (`CREATE TYPE ... AS`), `enum` de PostgreSQL, arreglos `seq[T]` y sobrecarga de funciones SQL | No |
| **04** | Serie 04 (`examples/04_*`) | Intermedio | Tipos binarios y complejos: `PgBytea`, `PgUuid`, `JsonNode` (`json`/`jsonb`), temporales y `PgNumeric` | No |
| **05** | Serie 05 (`examples/05_*`) | Intermedio | Funciones SRF (`SETOF`) e iteradores streaming `O(1)` en memoria y manejo limpio de errores | No |
| **06** | Serie 06 (`examples/06_*`) | Intermedio | Tipos base personalizados (`{.pgxType.}`), `pgxInput` / `pgxOutput` / `pgxReceive` / `pgxSend` y manejo de memoria ARC | No |
| **07** | [`07_multimodule_and_procedures/`](07_multimodule_and_procedures/) | Avanzado | Arquitectura multi-módulo (`main.nim` + `billing_ops.nim`), `{.pgxInit.}` en submódulos, `{.noSql.}`, metadata `pgxext.json` + `pgxExtension:`, `PROCEDURE` SQL (`CALL`), `{.securityDefiner, searchPath.}`, `{.leakproof.}` y migraciones `0.1.0 → 0.2.0` | No |
| **08** | [`08_query_builder_and_binary_spi/`](08_query_builder_and_binary_spi/) | Avanzado | `QueryBuilder` fluent + **SPI Binario v2**: parámetros `$1`/`$2`, `fetch[Row]`, `Option[string]` (`NULL` vs `""`), planes preparados (`spiPrepare keep = true`) y cursores streaming (`spiCursorOpen`/`Fetch`/`Close` y `stream[Row]`) | No |
| **09** | [`09_xact_callbacks_and_savepoints/`](09_xact_callbacks_and_savepoints/) | Avanzado | Callbacks transaccionales (`registerXactCallback`, `onCommit`, `onAbort`, `onPreCommit`), subtransacciones (`registerSubXactCallback`, `SAVEPOINT`), `pgxWithLibcAlloc` y **Anti-PANIC Shield** | No |
| **10** | [`10_shared_memory_and_bgworker/`](10_shared_memory_and_bgworker/) | Producción / Arquitectura | Memoria compartida (`{.pgxShared.}`, `initShmemStruct`), atómicos y `LWLock` (`getNamedTranche` + `withLock`), y `BgWorker` dinámico (`bgWorker`, `runWorkerLoop`, ciclo start/stop/estado) | **Sí (`tests/preload`)** |
| **11** | [`11_secure_gucs_and_composable_hooks/`](11_secure_gucs_and_composable_hooks/) | Producción / Arquitectura | GUCs seguros con RBAC (`gcUserset`, `gcSuset`, `superuserOnly`, `reserveGucPrefix`, `SET LOCAL`), hooks componibles (`hooks/registry`: `ExecutorEnd` + `ProcessUtility`), auditoría Security v2 (3 capas) y atestación en vivo (`verifyCatalogIntegrity`, `loadedSoSha256`) | **Sí (`tests/preload`)** |
| **12** | [`12_plugins_and_custom_templates/`](12_plugins_and_custom_templates/) | Producción / Arquitectura | Extensibilidad dual v0.33: **Plugin en Nim** (`plugin_api.nim`: `pgxSql` `pre`/`post`, traits `mixin`, `registerPgxPluginInit` + Binary SPI v2) y **Template propio** (`custom_template/` para `pgxtool new --template`) | No |

---

## Guía Rápida Universal

Todos los ejemplos siguen la misma estructura estándar (`pgxext.json`, `src/main.nim`, `tests/sql/*.sql`, `tests/expected/*.out` y `README.md`) y se operan con `pgxtool`:

### 1. Compilar una extensión

```bash
pgxtool build-extension examples/<dir>
```

Genera la librería compartida (`.so`), `<ext>.control`, `<ext>--<ver>.sql`, `<ext>.functions.json`, el manifiesto de integridad `<ext>.integrity.json` y el script `src/install.sh`.

### 2. Verificar seguridad e integridad (Security v2)

```bash
pgxtool verify examples/<dir>
```

Audita el binario ELF (símbolos OS prohibidos, `RPATH/RUNPATH`, `DT_NEEDED`), las hashes SHA-256 de `.so`/`.sql`/`.control` y, si defines `PGX_INTEGRITY_KEY`, la firma HMAC-SHA256 (`--require-signature`).

### 3. Probar en PostgreSQL 14–18 mediante Docker

```bash
# Probar contra una versión específica (ej. PostgreSQL 18)
pgxtool test examples/<dir> --pg 18

# Probar la matriz completa de versiones soportadas (PG 14, 15, 16, 17 y 18)
pgxtool test examples/<dir> --all
```

> Si el ejemplo incluye `tests/preload` (como **10** y **11**), `pgxtool test` configura `shared_preload_libraries` y reinicia PostgreSQL dentro del contenedor automáticamente.

### 4. Instalar y probar manualmente en `psql`

```bash
sudo ./examples/<dir>/src/install.sh
```

Si el ejemplo requiere `shared_preload_libraries`, agrégalo y reinicia PostgreSQL antes de crear la extensión. Al ejecutar `CREATE EXTENSION` en `psql`, **comilla siempre el nombre del directorio** porque empieza con dígitos:

```sql
CREATE EXTENSION "<dir>";
```

### 5. Arrancar un nuevo proyecto con plantillas (`pgxtool new`)

```bash
# Listar plantillas integradas y externas disponibles
pgxtool list-templates

# Crear un servicio listo para producción basado en la plantilla secure-service
pgxtool new ./mi_ext --template secure-service --var guc_prefix=mi_svc

# Compilar, verificar y probar el proyecto recién creado
pgxtool build-extension ./mi_ext
pgxtool verify ./mi_ext
pgxtool test ./mi_ext --all
```

---

## Benchmarks y Pruebas de Estrés Existentes

Además de la serie progresiva `01`–`12`, el directorio conserva las siguientes utilidades y escenarios de referencia:

- **[`payment_benchmark.sql`](payment_benchmark.sql)**: Genera las tablas transaccionales `payments` (10,000 filas) y `payments_history` para realizar benchmarks de archivado por lotes con Background Workers (`pgxWorker` / `bgWorker`).
- **[`memory_chaos_test/`](memory_chaos_test/)**: Escenario de estrés (`memory_chaos_test.nim` + `test_chaos.sql`) que ejercita el colector `--mm:arc` de Nim, la limpieza de `MemoryContext` de PostgreSQL frente a errores y los guards de SPI bajo carga.
