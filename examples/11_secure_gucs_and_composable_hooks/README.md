# Ejemplo 11 — GUCs Seguros (RBAC), Hooks Componibles, Auditoría e Integridad

Este ejemplo reúne el stack completo de **seguridad e introspección `v0.32 + v0.33`** de `pgxcrown`: parámetros GUC con control de acceso RBAC, hooks componibles del kernel cohabitando con UDFs en un único `.so`, auditoría binaria Security v2 (3 capas) y atestación criptográfica en vivo.

## Qué demuestra

1. **GUCs Seguros con RBAC y `reserveGucPrefix`**:
   - `defineGucInt("ex11.max_rows", ..., context = gcUserset)`: modificable por usuarios regulares y compatible con `SET LOCAL` + `ROLLBACK`.
   - `defineGucBool("ex11.strict_guard", ..., context = gcSuset)`: reservado a superusuarios (`42501` para otros roles).
   - `defineGucString("ex11.audit_token", ..., superuserOnly = true)`: aplica `GUC_SUPERUSER_ONLY` + `GUC_NO_SHOW_ALL`, ocultándolo de `pg_settings` y bloqueando `SHOW` / `getGuc` para roles sin privilegios.
   - `reserveGucPrefix("ex11")`: impide que terceros manipulen o inyecten parámetros bajo `ex11.*`.
2. **Hooks Componibles (`pgxcrown/hooks/registry`) + UDFs en el mismo `.so`**:
   - `registerExecutorEndHook` mide consultas y filas procesadas sobre `ex11_tracked_tbl` (filtrando consultas de control mediante `isInternalHookCtrlQuery`).
   - `registerProcessUtilityHook` intercepta sentencias DDL y bloquea `DROP TABLE ex11_protected_tbl` lanzando SQLSTATE `42501` (`insufficient_privilege`), mientras permite `DROP TABLE ex11_scratch_tbl`.
3. **Auditoría Security v2 (3 capas) y Atestación en vivo**:
   - En build-time, `pgxtool` audita símbolos OS restringidos, `RPATH/RUNPATH`, dependencias `DT_NEEDED` y genera `<ext>.integrity.json`.
   - En runtime SQL, `verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)`, `assertCatalogIntact(...)` y `loadedSoSha256(PgxExtensionName)` validan que `pg_proc` no haya sufrido alteraciones (`ALTER FUNCTION ... VOLATILE`, reemplazos PL/pgSQL, etc.) y que el SHA-256 de 64 caracteres hexadecimales de la librería cargada en memoria sea íntegro.

## Estructura de archivos

```text
11_secure_gucs_and_composable_hooks/
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
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks
pgxtool verify examples/11_secure_gucs_and_composable_hooks
pgxtool test examples/11_secure_gucs_and_composable_hooks --pg 18
pgxtool test examples/11_secure_gucs_and_composable_hooks --all
```

## Verificación criptográfica con firma HMAC (`--require-signature`)

Para entornos de producción o CI/CD con firma obligatoria de artefactos (Capa 3 de Security v2):

```bash
# 1. Definir clave secreta HMAC-SHA256 al compilar
export PGX_INTEGRITY_KEY="mi-clave-secreta-de-produccion"

# 2. Compilar generando <ext>.integrity.json firmado con HMAC-SHA256
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks --force

# 3. Exigir firma válida sobre .so, .control, .sql y manifiesto antes de desplegar
pgxtool verify examples/11_secure_gucs_and_composable_hooks --require-signature

# 4. (Tras instalar en PostgreSQL) Verificar también los archivos ya instalados
pgxtool verify 11_secure_gucs_and_composable_hooks --installed --require-signature
```

## Instalación y prueba manual en `psql`

```bash
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks
sudo ./examples/11_secure_gucs_and_composable_hooks/src/install.sh
```

Habilita `shared_preload_libraries` en PostgreSQL y reinicia el servidor:

```sql
ALTER SYSTEM SET shared_preload_libraries = '11_secure_gucs_and_composable_hooks';
-- Reiniciar PostgreSQL
```

```sql
CREATE EXTENSION "11_secure_gucs_and_composable_hooks";

SHOW ex11.max_rows;
SELECT ex11_guc_status();
SELECT ex11_integrity_report();
SELECT ex11_assert_intact();
```
