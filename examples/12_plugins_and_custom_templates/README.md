# Example 12: Nim Plugins (`plugin_api`) vs Custom Project Templates (`pgxtool new --template`)

This example clearly distinguishes and demonstrates **both complementary extensibility mechanisms in `pgxcrown` v0.33**:

1. **Nim Plugins (`pgxcrown/plugin_api`)**: *code-level* extensibility (reusable Nim modules contributing SQL types, `pre`/`post` DDL, `mixin` traits, and `_PG_init` initialization hooks).
2. **Scaffolding Templates (`pgxtool new --template`)**: *project-level* extensibility (declarative `template.json` templates that scaffold complete extensions ready to build and test).

## When to Use `plugin_api` vs `pgxtool new --template`

```text
+--------------------------------------------------------------------------------+
|                   TWO EXTENSIBILITY LEVELS IN PGXCROWN                         |
+---------------------------------------+----------------------------------------+
|  1) plugin_api.nim (Nim Module)       |  2) pgxtool new --template (Template)  |
+---------------------------------------+----------------------------------------+
|  WHEN TO USE IT:                      |  WHEN TO USE IT:                       |
|  • Share a custom type or domain      |  • Bootstrap new SQL projects or       |
|    across multiple extensions.        |    microservices in seconds.           |
|  • Inject declarative DDL with        |  • Standardize directory layout,       |
|    pgxSql(..., phase="pre"|"post").   |    pg_regress tests, pgxext.json,      |
|  • Bridge types to QueryBuilder via   |    and README documentation.           |
|    mixin (pgxSqlType/ToDatum/From/    |  • Parameterize names and variables    |
|    toParam).                          |    with --var key=val and safe regex.  |
|  • Register init in _PG_init with     |                                        |
|    registerPgxPluginInit(...).        |  WHEN IT RUNS:                         |
|                                       |  • At code-generation / scaffolding    |
|  WHEN IT RUNS:                        |    time (before Nim compilation).      |
|  • At compile time (pgx.nim) and      |                                        |
|    .so load time in PostgreSQL        |                                        |
|    (_PG_init).                        |                                        |
+---------------------------------------+----------------------------------------+
```

---

## Part 1 — Nim Plugin (`src/audit_plugin.nim` + `src/main.nim`)

### What It Demonstrates
- `pgxSql("ex12_audit_pre_table", ..., phase = "pre")` creates `ex12_audit_log` **before** generated types and functions in the installation SQL script.
- `pgxSql("ex12_audit_post_idx", ..., phase = "post")` and `ex12_audit_post_view` create indexes and views **after** tables and UDFs exist.
- The custom type `Ex12AuditTag* {.pgxType: string.}` implements the `mixin` trait contract:
  - `pgxSqlType`
  - `pgxToDatum`
  - `pgxFromDatum`
  - `toParam`
  Consumed in `src/main.nim` via `pluginSqlType`, `pluginToDatum`, `pluginFromDatum`, and `pluginToParam` alongside **Binary SPI v2 `QueryBuilder`** (`InsertInto`, `Select ... fetch(Ex12AuditRow)`, and `Option[string]`).
- `registerPgxPluginInit(onEx12PluginInit)` executes automatically and idempotently during `_PG_init` without needing to declare `{.pgxInit.}` in `main.nim`.

### Building, Verifying, and Testing Part 1

```bash
pgxtool build-extension examples/12_plugins_and_custom_templates
pgxtool verify examples/12_plugins_and_custom_templates
pgxtool test examples/12_plugins_and_custom_templates --pg 18
pgxtool test examples/12_plugins_and_custom_templates --all
```

### Installing Manually in `psql`

```bash
pgxtool build-extension examples/12_plugins_and_custom_templates
sudo ./examples/12_plugins_and_custom_templates/src/install.sh
```

```sql
CREATE EXTENSION "12_plugins_and_custom_templates";

SELECT ex12_plugin_ready();
SELECT ex12_describe_tag('  SecOps  '::"Ex12AuditTag");
SELECT ex12_record_audit('secops'::"Ex12AuditTag", 'demo_event');
SELECT ex12_fetch_audit('secops'::"Ex12AuditTag");
SELECT * FROM ex12_audit_summary;
```

---

## Part 2 — Custom Scaffolding Template (`custom_template/`)

The `custom_template/` subdirectory is a complete external template ready for use with `pgxtool new`:

```text
12_plugins_and_custom_templates/
├── pgxext.json
├── README.md
├── src/
│   ├── audit_plugin.nim        # Part 1: Reusable Nim plugin (plugin_api)
│   └── main.nim                # Part 1: Main extension + Binary SPI v2
├── tests/
│   ├── sql/01_demo.sql
│   └── expected/01_demo.out
└── custom_template/            # Part 2: Local template for pgxtool new
    ├── template.json
    ├── pgxext.json
    ├── README.md
    ├── src/main.nim
    └── regress/
        ├── sql/01_basic.sql
        └── expected/01_basic.out
```

### Scaffolding and Testing the Custom Template

```bash
# 1. Scaffold a new extension from the local template with a custom variable
pgxtool new ./my_service \
  --template examples/12_plugins_and_custom_templates/custom_template \
  --var service_tag=demo

# 2. Build and verify artifact integrity of the newly generated project
pgxtool build-extension ./my_service
pgxtool verify ./my_service

# 3. Run its own SQL regression test suite across PostgreSQL 14–18
pgxtool test ./my_service --all
```

You can also copy `custom_template/` into `$PGXTOOL_HOME/templates/ex12-custom-service` so it appears automatically when running `pgxtool list-templates`.
