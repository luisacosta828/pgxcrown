# {{project_name}}

Generated with `pgxcrown` v{{pgxcrown_version}} (`starter-udf` template, author: {{author}}).
Includes an auto-synchronized `nim.cfg` for `nimlangserver` / `nim check`.

## Build, Verify & Test

```bash
pgxtool build-extension .
pgxtool verify .
pgxtool test . --all
```
