# Example 11: Secure GUCs (RBAC), Composable Hooks, Auditing, and Integrity Attestation

This example brings together `pgxcrown`'s complete **`v0.32 + v0.33` security and introspection stack**: RBAC-enforced GUC parameters, composable engine hooks coexisting with UDFs in a single `.so`, 3-layer Security v2 binary auditing, and live cryptographic catalog/ELF attestation.

## What This Example Demonstrates

1. **RBAC-hardened GUCs and `reserveGucPrefix`**:
   - `defineGucInt("ex11.max_rows", ..., context = gcUserset)`: modifiable by regular users and supports `SET LOCAL` + `ROLLBACK`.
   - `defineGucBool("ex11.strict_guard", ..., context = gcSuset)`: restricted to superusers (`SQLSTATE 42501` for non-superusers).
   - `defineGucString("ex11.audit_token", ..., superuserOnly = true)`: applies `GUC_SUPERUSER_ONLY` + `GUC_NO_SHOW_ALL`, hiding the parameter from `pg_settings` and blocking `SHOW` / `getGuc` for unprivileged roles.
   - `reserveGucPrefix("ex11")`: prevents third-party extensions or SQL sessions from injecting or tampering with parameters under `ex11.*`.
2. **Composable Hooks (`pgxcrown/hooks/registry`) + UDFs in the same `.so`**:
   - `registerExecutorEndHook` counts queries and processed rows against `ex11_tracked_tbl` (filtering control queries via `isInternalHookCtrlQuery`).
   - `registerProcessUtilityHook` intercepts DDL statements and blocks `DROP TABLE ex11_protected_tbl` with `SQLSTATE 42501` (`insufficient_privilege`), while allowing `DROP TABLE ex11_scratch_tbl`.
3. **3-layer Security v2 audit and live runtime attestation**:
   - At build time, `pgxtool` audits restricted OS symbols, `RPATH`/`RUNPATH`, and `DT_NEEDED` dependencies, and generates `<ext>.integrity.json`.
   - At SQL runtime, `verifyCatalogIntegrity(PgxExtensionName, PgxCompiledFunctions)`, `assertCatalogIntact(...)`, and `loadedSoSha256(PgxExtensionName)` verify that `pg_proc` has not been tampered with (`ALTER FUNCTION ... VOLATILE`, PL/pgSQL replacements, etc.) and confirm the 64-hex-character SHA-256 digest of the `.so` loaded in memory.

## File Layout

```text
11_secure_gucs_and_composable_hooks/
├── pgxext.json
├── README.md
├── src/
│   └── main.nim
└── tests/
    ├── preload                 # Enables shared_preload_libraries in pgxtool test
    ├── sql/01_demo.sql
    └── expected/01_demo.out
```

## Building, Verifying, and Testing

```bash
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks
pgxtool verify examples/11_secure_gucs_and_composable_hooks
pgxtool test examples/11_secure_gucs_and_composable_hooks --pg 18
pgxtool test examples/11_secure_gucs_and_composable_hooks --all
```

## Cryptographic Verification with HMAC Signatures (`--require-signature`)

For production or CI/CD pipelines requiring signed extension artifacts (Security v2 Layer 3):

```bash
# 1. Set the HMAC-SHA256 signing key at build time
export PGX_INTEGRITY_KEY="my-production-secret-key"

# 2. Build and emit an HMAC-SHA256-signed <ext>.integrity.json manifest
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks --force

# 3. Require a valid signature over .so, .control, .sql, and manifest before deploying
pgxtool verify examples/11_secure_gucs_and_composable_hooks --require-signature

# 4. (After installing into PostgreSQL) Verify the installed artifacts as well
pgxtool verify 11_secure_gucs_and_composable_hooks --installed --require-signature
```

## Installing and Testing Manually in `psql`

```bash
pgxtool build-extension examples/11_secure_gucs_and_composable_hooks
sudo ./examples/11_secure_gucs_and_composable_hooks/src/install.sh
```

Enable `shared_preload_libraries` in PostgreSQL and restart the server:

```sql
ALTER SYSTEM SET shared_preload_libraries = '11_secure_gucs_and_composable_hooks';
-- Restart PostgreSQL
```

```sql
CREATE EXTENSION "11_secure_gucs_and_composable_hooks";

SHOW ex11.max_rows;
SELECT ex11_guc_status();
SELECT ex11_integrity_report();
SELECT ex11_assert_intact();
```
