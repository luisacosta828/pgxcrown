# {{project_name}}

Generated with `pgxcrown` v{{pgxcrown_version}} (`secure-service` template, GUC prefix `{{guc_prefix}}`).

Combines `pgxcrown` v0.32 + v0.33 capabilities:
- Secure GUCs (`{{guc_prefix}}.max_limit`, `{{guc_prefix}}.strict_mode`, `reserveGucPrefix`)
- Binary SPI v2 parameterized `QueryBuilder` with `Option[string]` (`NULL` vs `""`)
- Transaction lifecycle callbacks (`onCommit` / `onAbort`)
- Live catalog integrity attestation (`verifyCatalogIntegrity`, `isCatalogIntact`, `loadedSoSha256`) and `pgxtool verify` compatibility

## Build, Verify & Test

```bash
pgxtool build-extension .
pgxtool verify .
pgxtool test . --all
```
