# Ejemplo 10 — Memoria Compartida, LWLocks y Background Workers Dinámicos

Este ejemplo demuestra cómo combinar **memoria compartida de PostgreSQL**, sincronización atómica y con **`LWLock`**, y un **Background Worker dinámico** que colabora con sesiones SQL en tiempo real usando `shared_preload_libraries`.

## Qué demuestra

1. **Dos estilos complementarios de memoria compartida**:
   - **Declarativo `{.pgxShared.}`**: `var gPragmaTicks {.pgxShared("ex10_pragma_ticks").}: Atomic[int64]` reserva e inicializa un slot atómico compartido entre procesos.
   - **Estructurado `initShmemStruct` + `{.pgxShmem.}`**: `Ex10SharedState` se dimensiona con `requestShmemSpace[Ex10SharedState]` y se inicializa atómicamente bajo `AddinShmemInitLock` en `onEx10ShmemStartup`.
2. **Sincronización con `LWLock` (`getNamedTranche` + `withLock`)**:
   - Reserva un tranche nombrado (`requestNamedTranche("ex10_tranche", 2)`) en startup y protege lecturas/escrituras concurrentes entre el worker y las sesiones SQL (`lwExclusive` / `lwShared`).
3. **Background Worker dinámico (`bgWorker` + `runWorkerLoop`)**:
   - Configura un worker con `library "10_shared_memory_and_bgworker"`, `entrypoint "ex10_metrics_worker"`, `database "postgres"` y `restart 30`.
   - Lo lanza dinámicamente desde SQL con `registerDynamicWorker`, supervisa su ciclo con `trackWorkerStarted`, `getWorkerStatusByName` y `stopWorkerByName`, y detiene el proceso limpiamente ante `SIGTERM`.
4. **Requisito de `tests/preload`**:
   - La presencia de `tests/preload` le indica a `pgxtool test` que configure `shared_preload_libraries = '10_shared_memory_and_bgworker'` y reinicie PostgreSQL antes de ejecutar `01_demo.sql`.

## Estructura de archivos

```text
10_shared_memory_and_bgworker/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── preload                 # Activa shared_preload_libraries en pgxtool test
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Cómo compilar, verificar y probar

```bash
pgxtool build-extension examples/10_shared_memory_and_bgworker
pgxtool verify examples/10_shared_memory_and_bgworker
pgxtool test examples/10_shared_memory_and_bgworker --pg 18
pgxtool test examples/10_shared_memory_and_bgworker --all
```

## Instalación y prueba manual en `psql`

```bash
pgxtool build-extension examples/10_shared_memory_and_bgworker
sudo ./examples/10_shared_memory_and_bgworker/src/install.sh
```

Habilita `shared_preload_libraries` en PostgreSQL y reinicia el servidor antes de crear la extensión:

```sql
ALTER SYSTEM SET shared_preload_libraries = '10_shared_memory_and_bgworker';
-- Reiniciar PostgreSQL (p. ej. pg_ctl restart)
```

```sql
CREATE EXTENSION "10_shared_memory_and_bgworker";

SELECT ex10_start_worker() > 0;
SELECT ex10_worker_status();
SELECT ex10_bump_shared(10);
SELECT ex10_lwlock_invariant_ok();
SELECT ex10_stop_worker();
SELECT ex10_worker_status();
```
