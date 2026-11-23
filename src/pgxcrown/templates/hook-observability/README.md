# {{project_name}}

Generated with `pgxcrown` v{{pgxcrown_version}} (`hook-observability` template, label `{{hook_label}}`, GUC prefix `{{guc_prefix}}`).

Uses composable `hooks/registry` (`registerPostParseHook` + `registerExecutorEndHook`) and Secure GUC gating (`{{guc_prefix}}.enabled`).

## Build & Test

```bash
pgxtool build-extension .
pgxtool test . --all
```
