# Ejemplo 09 — Callbacks Transaccionales, Savepoints y Anti-PANIC Shield

Este ejemplo demuestra la API de callbacks transaccionales de `pgxcrown` (`v0.32`): `registerXactCallback` (`onPreCommit`, `onCommit`, `onAbort`), `registerSubXactCallback` para subtransacciones (`SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`), aislamiento de memoria con `pgxWithLibcAlloc` y el **Anti-PANIC Shield** durante `xeAbort`.

## Qué demuestra

1. **Callbacks de transacción (`registerXactCallback`, `onCommit`, `onAbort`, `onPreCommit`)**:
   - Ejecución determinista en `COMMIT`, `ROLLBACK` y validación previa en `xePreCommit` (donde sí es válido abortar con `raisePgError`).
   - Registro one-shot (`once = true`) con limpieza automática tras dispararse o abortar.
2. **Subtransacciones (`registerSubXactCallback`)**:
   - Observa `sxeStartSub`, `sxePreCommitSub`, `sxeCommitSub` y `sxeAbortSub` ante `SAVEPOINT`, `ROLLBACK TO SAVEPOINT` y `RELEASE SAVEPOINT`.
3. **Seguridad de memoria con `pgxWithLibcAlloc`**:
   - Cuando una extensión se compila con `--wrap=malloc` bajo PostgreSQL, las asignaciones dentro de un UDF viven por defecto en el `MemoryContext` activo de la transacción/sentencia.
   - `pgxWithLibcAlloc:` fuerza temporalmente `libc malloc` para los closures y logs (`gAuditLog`) que deben sobrevivir más allá del reset del `TopTransactionContext`.
4. **Anti-PANIC Shield en `xeAbort` / `xeCommit`**:
   - En PostgreSQL, lanzar un `ERROR` (`ereport(ERROR)` / `longjmp`) durante `XACT_EVENT_ABORT` o `XACT_EVENT_COMMIT` provoca un `PANIC` y tumba todo el clúster.
   - El Anti-PANIC Shield de `pgxcrown` intercepta excepciones Nim y errores PostgreSQL en fases no abortables, emite un `WARNING` controlado y permite que continúen los callbacks restantes sin caída del servidor.

## Estructura de archivos

```text
09_xact_callbacks_and_savepoints/
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
pgxtool build-extension examples/09_xact_callbacks_and_savepoints
pgxtool verify examples/09_xact_callbacks_and_savepoints
pgxtool test examples/09_xact_callbacks_and_savepoints --pg 18
pgxtool test examples/09_xact_callbacks_and_savepoints --all
```

## Instalación y prueba manual en `psql`

```bash
pgxtool build-extension examples/09_xact_callbacks_and_savepoints
sudo ./examples/09_xact_callbacks_and_savepoints/src/install.sh
```

```sql
CREATE EXTENSION "09_xact_callbacks_and_savepoints";

SELECT ex09_reset();
BEGIN;
SELECT ex09_arm_tx('demo');
COMMIT;
SELECT ex09_take_log(false);

BEGIN;
SELECT ex09_arm_abort_shield();
ROLLBACK; -- Emite WARNING en lugar de PANIC
SELECT ex09_take_log(true);
```
