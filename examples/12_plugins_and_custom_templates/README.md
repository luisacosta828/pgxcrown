# Ejemplo 12 — Plugins en Nim (`plugin_api`) vs Templates Personalizados (`pgxtool new --template`)

Este ejemplo aclara y demuestra paso a paso **las dos caras complementarias de extensibilidad en `pgxcrown` v0.33**:

1. **Plugins en Nim (`pgxcrown/plugin_api`)**: extensibilidad *en código* (módulos reutilizables que aportan tipos SQL, DDL `pre`/`post`, traits `mixin` y hooks de inicialización en `_PG_init`).
2. **Templates de Scaffolding (`pgxtool new --template`)**: extensibilidad *de proyecto* (plantillas declarativas con `template.json` para generar nuevas extensiones completas listas para compilar y probar).

## ¿Cuándo usar `plugin_api` vs `pgxtool new --template`?

```text
+--------------------------------------------------------------------------------+
|                   DOS NIVELES DE EXTENSIBILIDAD EN PGXCROWN                    |
+---------------------------------------+----------------------------------------+
|  1) plugin_api.nim (Módulo Nim)       |  2) pgxtool new --template (Plantilla) |
+---------------------------------------+----------------------------------------+
|  CUÁNDO USARLO:                       |  CUÁNDO USARLO:                        |
|  • Compartir un tipo custom o dominio |  • Arrancar proyectos o micro-         |
|    entre varias extensiones.          |    servicios SQL nuevos en segundos.   |
|  • Inyectar DDL declarativo con       |  • Estandarizar estructura, tests      |
|    pgxSql(..., phase="pre"|"post").   |    pg_regress, pgxext.json y README.   |
|  • Conectar tipos al QueryBuilder vía |  • Parametrizar nombres y variables    |
|    mixin (pgxSqlType/ToDatum/From/    |    con --var key=val y regex seguro.   |
|    toParam).                          |                                        |
|  • Registrar init en _PG_init con     |  CUÁNDO SE EJECUTA:                    |
|    registerPgxPluginInit(...).        |  • En tiempo de generación de código   |
|                                       |    (antes de compilar con Nim).        |
|  CUÁNDO SE EJECUTA:                   |                                        |
|  • En compilación (pgx.nim) y carga   |                                        |
|    del .so en PostgreSQL (_PG_init).  |                                        |
+---------------------------------------+----------------------------------------+
```

---

## Parte 1 — Plugin en Nim (`src/audit_plugin.nim` + `src/main.nim`)

### Qué demuestra
- `pgxSql("ex12_audit_pre_table", ..., phase = "pre")` crea `ex12_audit_log` **antes** que los tipos y funciones del `.sql` generado.
- `pgxSql("ex12_audit_post_idx", ..., phase = "post")` y `ex12_audit_post_view` crean índices y vistas **después** de que existan las tablas y UDFs.
- El tipo custom `Ex12AuditTag* {.pgxType: string.}` implementa el contrato `mixin`:
  - `pgxSqlType`
  - `pgxToDatum`
  - `pgxFromDatum`
  - `toParam`
  Consumido desde `src/main.nim` mediante `pluginSqlType`, `pluginToDatum`, `pluginFromDatum` y `pluginToParam` junto con **Binary SPI v2 `QueryBuilder`** (`InsertInto`, `Select ... fetch(Ex12AuditRow)` y `Option[string]`).
- `registerPgxPluginInit(onEx12PluginInit)` se ejecuta automáticamente e idempotentemente durante `_PG_init`, sin necesidad de declarar `{.pgxInit.}` en `main.nim`.

### Compilar, verificar y probar la Parte 1

```bash
pgxtool build-extension examples/12_plugins_and_custom_templates
pgxtool verify examples/12_plugins_and_custom_templates
pgxtool test examples/12_plugins_and_custom_templates --pg 18
pgxtool test examples/12_plugins_and_custom_templates --all
```

### Instalación manual en `psql`

```bash
pgxtool build-extension examples/12_plugins_and_custom_templates
sudo ./examples/12_plugins_and_custom_templates/src/install.sh
```

```sql
CREATE EXTENSION "12_plugins_and_custom_templates";

SELECT ex12_plugin_ready();
SELECT ex12_describe_tag('  SecOps  '::"Ex12AuditTag");
SELECT ex12_record_audit('secops'::"Ex12AuditTag", 'evento_demo');
SELECT ex12_fetch_audit('secops'::"Ex12AuditTag");
SELECT * FROM ex12_audit_summary;
```

---

## Parte 2 — Template de Scaffolding propio (`custom_template/`)

El subdirectorio `custom_template/` es una plantilla externa completa lista para usar con `pgxtool new`:

```text
12_plugins_and_custom_templates/
├── pgxext.json
├── README.md
├── src/
│   ├── audit_plugin.nim        # Parte 1: Plugin Nim reutilizable (plugin_api)
│   └── main.nim                # Parte 1: Extensión principal + Binary SPI v2
├── tests/
│   ├── sql/01_demo.sql
│   └── expected/01_demo.out
└── custom_template/            # Parte 2: Template local para pgxtool new
    ├── template.json
    ├── pgxext.json
    ├── README.md
    ├── src/main.nim
    └── regress/
        ├── sql/01_basic.sql
        └── expected/01_basic.out
```

### Instanciar y probar el template personalizado

```bash
# 1. Crear una nueva extensión desde el template local con variable personalizada
pgxtool new ./mi_servicio \
  --template examples/12_plugins_and_custom_templates/custom_template \
  --var service_tag=demo

# 2. Compilar y verificar integridad del proyecto recién generado
pgxtool build-extension ./mi_servicio
pgxtool verify ./mi_servicio

# 3. Ejecutar su propia suite de regresión en PG 14–18
pgxtool test ./mi_servicio --all
```

También puedes copiar `custom_template/` dentro de `$PGXTOOL_HOME/templates/ex12-custom-service` para que aparezca automáticamente al listar con `pgxtool list-templates`.
