import std/[json, os, strutils, tables, unittest]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

import ../src/pgxcrown/ext_meta
import ../src/pgxcrown/query_builder
import ../src/pgxcrown/plugin_api
import ../src/pgxcrown/template_engine

type
  DemoPluginPoint = object
    x: int32
    y: int32

proc pgxSqlType(_: typedesc[DemoPluginPoint]): string =
  "point_text"

proc pgxToDatum(p: DemoPluginPoint): Datum =
  let packed = (uint64(uint32(p.x)) shl 32) or uint64(uint32(p.y))
  Datum(packed)

proc pgxFromDatum(_: typedesc[DemoPluginPoint], d: Datum): DemoPluginPoint =
  let raw = uint64(d)
  DemoPluginPoint(
    x: cast[int32](uint32((raw shr 32) and 0xFFFF_FFFF'u64)),
    y: cast[int32](uint32(raw and 0xFFFF_FFFF'u64))
  )

proc toParam(p: DemoPluginPoint): QueryParam =
  toParam($p.x & "," & $p.y)

pgxSql("unit_test_noop", "SELECT 1;", phase = "pre")
pgxSql("unit_test_noop_default", "SELECT 2;")

var gPluginInitLog {.global.}: seq[string] = @[]

proc cbAlpha() {.gcsafe.} =
  {.cast(gcsafe).}:
    gPluginInitLog.add("alpha")

proc cbBeta() {.gcsafe.} =
  {.cast(gcsafe).}:
    gPluginInitLog.add("beta")

proc cbGamma() {.gcsafe.} =
  {.cast(gcsafe).}:
    gPluginInitLog.add("gamma")

proc cbDummy() {.gcsafe.} =
  discard

suite "Pgxcrown v0.33.0 - Plugin API, Schema CustomSQL & Template Engine":

  test "CustomSqlSchema JSON roundtrip, legacy compatibility, and pre/post migration diff":
    let legacyJson = parseJson("""{
      "version": "0.1.0",
      "enums": [],
      "composites": [],
      "baseTypes": [],
      "routines": []
    }""")
    let legacySnap = jsonToSnapshot(legacyJson)
    check legacySnap.version == "0.1.0"
    check legacySnap.customSql.len == 0

    let snap1 = SchemaSnapshot(
      version: "0.1.0",
      enums: @[],
      composites: @[],
      baseTypes: @[],
      routines: @[
        RoutineSchema(sigKey: "fn_a()", ddl: "CREATE OR REPLACE FUNCTION fn_a() returns int4 as 'ext', 'pgx_fn_a' language c IMMUTABLE STRICT;")
      ],
      customSql: @[
        CustomSqlSchema(id: "pre_keep", phase: "pre", ddl: "CREATE TABLE keep_tbl (id int);"),
        CustomSqlSchema(id: "mod_blk", phase: "post", ddl: "CREATE INDEX idx_old ON keep_tbl(id);"),
        CustomSqlSchema(id: "drop_blk", phase: "post", ddl: "CREATE VIEW old_v AS SELECT 1;")
      ]
    )
    let snap2 = SchemaSnapshot(
      version: "0.2.0",
      enums: @[EnumSchema(name: "Role", labels: @["user"])],
      composites: @[],
      baseTypes: @[],
      routines: @[
        RoutineSchema(sigKey: "fn_a()", ddl: "CREATE OR REPLACE FUNCTION fn_a() returns int4 as 'ext', 'pgx_fn_a' language c IMMUTABLE STRICT;"),
        RoutineSchema(sigKey: "fn_b()", ddl: "CREATE OR REPLACE FUNCTION fn_b() returns int4 as 'ext', 'pgx_fn_b' language c IMMUTABLE STRICT;")
      ],
      customSql: @[
        CustomSqlSchema(id: "pre_keep", phase: "pre", ddl: "CREATE TABLE keep_tbl (id int);"),
        CustomSqlSchema(id: "pre_new", phase: "pre", ddl: "CREATE TABLE new_pre_tbl (k text PRIMARY KEY);"),
        CustomSqlSchema(id: "mod_blk", phase: "post", ddl: "CREATE INDEX idx_new ON keep_tbl(id);"),
        CustomSqlSchema(id: "post_new", phase: "post", ddl: "CREATE VIEW new_v AS SELECT * FROM new_pre_tbl;")
      ]
    )

    let rt = jsonToSnapshot(snapshotToJson(snap2))
    check rt.customSql.len == 4
    check rt.customSql[1].id == "pre_new"
    check rt.customSql[1].phase == "pre"

    let mig = diffSnapshotsAndBuildMigration(snap1, snap2)
    let prePos = mig.find("CREATE TABLE new_pre_tbl")
    let enumPos = mig.find("CREATE TYPE \"Role\" AS ENUM")
    let fnPos = mig.find("CREATE OR REPLACE FUNCTION fn_b()")
    let postPos = mig.find("CREATE VIEW new_v")
    check prePos >= 0
    check enumPos > prePos
    check fnPos > enumPos
    check postPos > fnPos
    check "CREATE TABLE keep_tbl" notin mig
    check "-- NOTE: Custom pgxSql block 'mod_blk' changed" in mig
    check "-- NOTE: Previous pgxSql block removed: drop_blk" in mig

  test "Plugin init registry: ordering, idempotency, nil safety, and capacity limit":
    resetPgxPluginInits()
    gPluginInitLog = @[]

    registerPgxPluginInit(nil)
    check pgxPluginInitCount == 0

    registerPgxPluginInit(cbAlpha)
    registerPgxPluginInit(cbBeta)
    check pgxPluginInitCount == 2

    runPgxPluginInits()
    check gPluginInitLog == @["alpha", "beta"]

    # Idempotent repeat invocation does not re-run completed hooks
    runPgxPluginInits()
    check gPluginInitLog == @["alpha", "beta"]

    # Late hook added afterwards runs once without re-running alpha/beta
    registerPgxPluginInit(cbGamma)
    runPgxPluginInits()
    check gPluginInitLog == @["alpha", "beta", "gamma"]
    runPgxPluginInits()
    check gPluginInitLog == @["alpha", "beta", "gamma"]

    # Fixed-size static array capacity enforcement
    resetPgxPluginInits()
    for _ in 0 ..< MAX_PGX_PLUGIN_INITS:
      registerPgxPluginInit(cbDummy)
    check pgxPluginInitCount == MAX_PGX_PLUGIN_INITS
    expect Defect:
      registerPgxPluginInit(cbDummy)
    resetPgxPluginInits()

  test "Stable mixin plugin contract bridges & compile-time pgxSql validation":
    let pt = DemoPluginPoint(x: 17'i32, y: -42'i32)
    check pluginSqlType(DemoPluginPoint) == "point_text"
    check pluginSqlType[DemoPluginPoint]() == "point_text"
    let d = pluginToDatum(pt)
    let back1 = pluginFromDatum(DemoPluginPoint, d)
    let back2 = pluginFromDatum[DemoPluginPoint](d)
    let back3 = pluginFromDatum(d, DemoPluginPoint)
    check back1 == pt
    check back2 == pt
    check back3 == pt
    check $pluginToParam(pt) == "'17,-42'"

    check not compiles(pgxSql("", "SELECT 1;"))
    check not compiles(pgxSql("bad_ddl", "   "))
    check not compiles(pgxSql("bad_phase", "SELECT 1;", phase = "during"))
    check not compiles(pgxSql("bad\0nul", "SELECT 1;"))

  test "Pure-Nim Thompson NFA regex matcher & SemVer checks":
    check regexMatch("^[a-z][a-z0-9_]*$", "my_ext_1")
    check not regexMatch("^[a-z][a-z0-9_]*$", "1bad_ext")
    check not regexMatch("^[a-z][a-z0-9_]*$", "bad-ext")
    check regexMatch("^foo", "foobar")
    check not regexMatch("^foo", "xfoo")
    check regexMatch("bar$", "foobar")
    check not regexMatch("bar$", "barx")
    check regexMatch("(alpha|beta)", "xbeta1")
    check not regexMatch("^(alpha|beta)$", "xbeta1")
    check regexMatch("a.c", "abc")
    check not regexMatch("a.c", "a\nc")
    check regexMatch("[^0-9]+", "abc")
    check not regexMatch("^[^0-9]+$", "a1c")
    check regexMatch("^\\d{2,4}\\.\\w+\\?$", "123.ok_1?")
    check not regexMatch("^\\d{2,4}\\.\\w+\\?$", "1.ok_1?")
    check regexMatch("^a*b+c?$", "bbbc")
    check regexMatch("^a*b+c?$", "aaab")
    check not regexMatch("^a*b+c?$", "aaa")

    # ReDoS resistance check: linear NFA completes immediately
    check not regexMatch("^(a+)+b$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaa!")

    expect ValueError:
      discard compileRegex("[unclosed")
    expect ValueError:
      discard compileRegex("(unclosed")
    expect ValueError:
      discard compileRegex("a{5,2}")

    check compareSemVer("0.31.0", "0.31.0") == 0
    check compareSemVer("0.32.0", "0.31.0") > 0
    check compareSemVer("0.30.9", "0.31.0") < 0
    check compareSemVer("1.0.0", "0.99.9") > 0

  test "Placeholder rendering and all 5 builtin templates scaffold cleanly":
    check toProjectSnake("my-cool-ext") == "my_cool_ext"
    check toProjectSnake("MyCoolExt") == "my_cool_ext"
    check toProjectSnake("123app") == "ext_123app"

    let vars = {"project_name": "demo", "other": "{{project_name}}"}.toTable
    # Single-pass substitution must not recursively expand {{project_name}} inside {{other}}
    check renderPlaceholders("{{other}}-{{project_name}}", vars) == "{{project_name}}-demo"

    let (listed, warnings) = listAvailableTemplates()
    check warnings.len == 0
    var names: seq[string] = @[]
    for t in listed:
      names.add(t.name)
    for expectedName in ["starter-udf", "base-type", "bgworker-service", "hook-observability", "plugin-custom-type"]:
      check expectedName in names

    let tmpRoot = getTempDir() / ("pgx_tpl_builtins_" & $getCurrentProcessId())
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    try:
      for tplName in ["starter-udf", "base-type", "bgworker-service", "hook-observability", "plugin-custom-type"]:
        let dest = tmpRoot / ("proj_" & tplName.replace("-", "_"))
        let res = scaffoldFromTemplate(tplName, dest, "0.31.0")
        check res.templateName == tplName
        check res.sourceKind == "builtin"
        check fileExists(dest / "pgxext.json")
        check fileExists(dest / "src" / "main.nim")
        check fileExists(dest / "tests" / "sql" / "01_basic.sql")
        check fileExists(dest / "tests" / "expected" / "01_basic.out")
        check "0.31.0" in readFile(dest / "README.md")
    finally:
      if dirExists(tmpRoot): removeDir(tmpRoot)

  test "External template discovery, --template dir, custom vars, and security hardening":
    let tmpRoot = getTempDir() / ("pgx_tpl_sec_" & $getCurrentProcessId())
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot / "home" / "templates" / "custom_ext" / "src")
    createDir(tmpRoot / "home" / "templates" / "custom_ext" / "tests" / "sql")
    createDir(tmpRoot / "direct_tpl" / "src")
    try:
      writeFile(tmpRoot / "home" / "templates" / "custom_ext" / "template.json", """{
        "name": "custom_ext",
        "description": "External template in PGXTOOL_HOME",
        "minPgxcrownVersion": "0.31.0",
        "variables": [
          {"name": "ident_slug", "default": "demo_slug", "pattern": "^[a-z][a-z0-9_]{2,20}$"}
        ],
        "files": [
          "src/main.nim",
          {"src": "src/sub.nim", "dest": "src/{{ident_slug}}.nim"},
          "tests/sql/01_basic.sql"
        ]
      }""")
      writeFile(tmpRoot / "home" / "templates" / "custom_ext" / "src" / "main.nim",
        "import pgxcrown\nimport ./{{ident_slug}}\n")
      writeFile(tmpRoot / "home" / "templates" / "custom_ext" / "src" / "sub.nim",
        "proc {{project_snake}}_{{ident_slug}}*(): int32 = 1\n")
      writeFile(tmpRoot / "home" / "templates" / "custom_ext" / "tests" / "sql" / "01_basic.sql",
        "SELECT {{project_snake}}_{{ident_slug}}();\n")

      let (listed, _) = listAvailableTemplates(tmpRoot / "home" / "templates")
      var foundCustom = false
      for t in listed:
        if t.name == "custom_ext" and t.sourceKind == "external":
          foundCustom = true
      check foundCustom

      let destOk = tmpRoot / "out_ok"
      let res = scaffoldFromTemplate(
        "custom_ext",
        destOk,
        "0.31.0",
        {"ident_slug": "tag_v2"}.toTable,
        externalTemplatesDir = tmpRoot / "home" / "templates"
      )
      check res.sourceKind == "external"
      check fileExists(destOk / "src" / "tag_v2.nim")
      check "proc out_ok_tag_v2*()" in readFile(destOk / "src" / "tag_v2.nim")

      # Invalid regex variable must be rejected
      expect ValueError:
        discard scaffoldFromTemplate(
          "custom_ext",
          tmpRoot / "out_bad_var",
          "0.31.0",
          {"ident_slug": "BAD-SLUG!"}.toTable,
          externalTemplatesDir = tmpRoot / "home" / "templates"
        )

      # Direct --template dir with minPgxcrownVersion too high must be rejected
      writeFile(tmpRoot / "direct_tpl" / "template.json", """{
        "name": "future_tpl",
        "description": "Requires newer pgxcrown",
        "minPgxcrownVersion": "0.99.0",
        "variables": [],
        "files": ["src/main.nim"]
      }""")
      writeFile(tmpRoot / "direct_tpl" / "src" / "main.nim", "import pgxcrown\n")
      expect ValueError:
        discard scaffoldFromTemplate(tmpRoot / "direct_tpl", tmpRoot / "out_future", "0.31.0")

      # Traversal '..' in target arg / project name rejected
      expect ValueError:
        discard scaffoldFromTemplate("starter-udf", tmpRoot / "x", "0.31.0", rawTargetArg = "../escape")
      expect ValueError:
        discard scaffoldFromTemplate("starter-udf", tmpRoot / "x", "0.31.0", rawTargetArg = "foo/../bar")

      # NUL and control characters in project names, var names/values, and filenames rejected
      expect ValueError:
        validateProjectName("bad\0name")
      expect ValueError:
        validateProjectName("bad\nname")
      expect ValueError:
        discard scaffoldFromTemplate("starter-udf", tmpRoot / "out_nul_var", "0.31.0", {"author": "a\0b"}.toTable)
      expect ValueError:
        discard scaffoldFromTemplate("starter-udf", tmpRoot / "out_ctrl_var", "0.31.0", {"author": "a\x1bb"}.toTable)
      expect ValueError:
        validateVariableName("bad\0key")
      expect ValueError:
        validateRelativeTemplatePath("src/bad\0.nim")
      expect ValueError:
        validateRelativeTemplatePath("src/bad\n.nim")

      # Absolute path or '..' in manifest files or variable destination rejected
      writeFile(tmpRoot / "direct_tpl" / "template.json", """{
        "name": "abs_tpl",
        "description": "Bad absolute path",
        "minPgxcrownVersion": "0.31.0",
        "variables": [],
        "files": ["/etc/passwd"]
      }""")
      expect ValueError:
        discard scaffoldFromTemplate(tmpRoot / "direct_tpl", tmpRoot / "out_abs", "0.31.0")

      writeFile(tmpRoot / "direct_tpl" / "template.json", """{
        "name": "trav_tpl",
        "description": "Bad traversal path",
        "minPgxcrownVersion": "0.31.0",
        "variables": [],
        "files": ["../escape.nim"]
      }""")
      expect ValueError:
        discard scaffoldFromTemplate(tmpRoot / "direct_tpl", tmpRoot / "out_trav", "0.31.0")

      writeFile(tmpRoot / "direct_tpl" / "template.json", """{
        "name": "var_dest_tpl",
        "description": "Variable destination path check",
        "minPgxcrownVersion": "0.31.0",
        "variables": [{"name": "dest_sub", "default": "ok.nim", "pattern": ""}],
        "files": [{"src": "src/main.nim", "dest": "{{dest_sub}}"}]
      }""")
      expect ValueError:
        discard scaffoldFromTemplate(tmpRoot / "direct_tpl", tmpRoot / "out_vardest_abs", "0.31.0", {"dest_sub": "/tmp/evil.nim"}.toTable)
      expect ValueError:
        discard scaffoldFromTemplate(tmpRoot / "direct_tpl", tmpRoot / "out_vardest_trav", "0.31.0", {"dest_sub": "../evil.nim"}.toTable)

      # Symlink escaping source template dir OR destination dir rejected
      when not defined(windows):
        let outsideFile = tmpRoot / "outside_secret.txt"
        writeFile(outsideFile, "TOP_SECRET")
        let symSrcDir = tmpRoot / "sym_tpl"
        createDir(symSrcDir / "src")
        writeFile(symSrcDir / "template.json", """{
          "name": "sym_tpl",
          "description": "Symlink escape test",
          "minPgxcrownVersion": "0.31.0",
          "variables": [],
          "files": ["src/leak.nim"]
        }""")
        createSymlink(outsideFile, symSrcDir / "src" / "leak.nim")
        expect ValueError:
          discard scaffoldFromTemplate(symSrcDir, tmpRoot / "out_sym_src", "0.31.0")

        # Relative symlink with .. escaping source template dir
        let symRelDir = tmpRoot / "sym_rel_tpl"
        createDir(symRelDir / "src")
        writeFile(symRelDir / "template.json", """{
          "name": "sym_rel_tpl",
          "description": "Relative symlink escape test",
          "minPgxcrownVersion": "0.31.0",
          "variables": [],
          "files": ["src/leak.nim"]
        }""")
        createSymlink("../../outside_secret.txt", symRelDir / "src" / "leak.nim")
        expect ValueError:
          discard scaffoldFromTemplate(symRelDir, tmpRoot / "out_sym_rel", "0.31.0")

        # Symlink in destination directory pointing outside
        let outsideDestDir = tmpRoot / "outside_dest"
        createDir(outsideDestDir)
        let victimDest = tmpRoot / "victim_dest"
        createDir(victimDest)
        createSymlink(outsideDestDir, victimDest / "src")
        expect ValueError:
          discard scaffoldFromTemplate("starter-udf", victimDest, "0.31.0")
        check not fileExists(outsideDestDir / "main.nim")
    finally:
      if dirExists(tmpRoot): removeDir(tmpRoot)
