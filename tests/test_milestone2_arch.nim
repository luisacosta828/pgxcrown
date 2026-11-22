import std/[os, strutils, unittest]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server").}

{.emit: """
#include "postgres.h"
#include "utils/elog.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

bool errstart(int elevel, const char *domain) { (void)elevel; (void)domain; return false; }
void errfinish(const char *filename, int lineno, const char *funcname) { (void)filename; (void)lineno; (void)funcname; }
int errcode(int sqlerrcode) { (void)sqlerrcode; return 0; }
int errmsg(const char *fmt, ...) { (void)fmt; return 0; }
int errdetail(const char *fmt, ...) { (void)fmt; return 0; }
int errhint(const char *fmt, ...) { (void)fmt; return 0; }
ErrorData *CopyErrorData(void) { return NULL; }
void FlushErrorState(void) {}
void pg_re_throw(void) { abort(); }
void FreeErrorData(ErrorData *edata) { (void)edata; }
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void pfree(void *ptr) { if (ptr) free(ptr); }
""" .}

import ../src/pgxcrown/reports/[errcodes, reports]
import ../src/pgxcrown/ext_meta
import ../src/pgxcrown/pgxtool

suite "Pgxcrown Milestone 2 - Architecture, Versioning, Mangling & Stack Guard":

  test "ERRCODE_STATEMENT_TOO_COMPLEX and host checkStackDepth weak symbol":
    check ERRCODE_PROGRAM_LIMIT_EXCEEDED.unpackSqlState() == "54000"
    check ERRCODE_STATEMENT_TOO_COMPLEX.unpackSqlState() == "54001"
    check ERRCODE_TOO_MANY_COLUMNS.unpackSqlState() == "54011"
    check ERRCODE_TOO_MANY_ARGUMENTS.unpackSqlState() == "54023"
    # Weak C stub allows direct invocation in host unit tests outside PostgreSQL
    checkStackDepth()

  test "Deterministic overload C symbol mangling and SQL collision keys":
    let sVoid = buildMangledCSymbol("calc", @[])
    let sI4 = buildMangledCSymbol("calc", @["int4"])
    let sI4Txt = buildMangledCSymbol("calc", @["int4", "Text"])
    let sArrEnum = buildMangledCSymbol("calc", @["int4[]", "\"PaymentState\""])
    for s in [sVoid, sI4, sI4Txt, sArrEnum]:
      check s.startsWith("pgx_calc_")
      check "__" notin s
      check not s.endsWith("_")
      check s.len <= 63
    check sVoid.endsWith("_void")
    check sI4.endsWith("_int4")
    check sI4Txt.endsWith("_int4_text")
    check sArrEnum.endsWith("_arr_int4_paymentstate")
    check sVoid != sI4 and sI4 != sI4Txt and sI4Txt != sArrEnum
    check buildMangledCSymbol("calc", @["int4"]) == sI4

    let longSig = @["int4", "int8", "float8", "text", "uuid", "bytea", "numeric", "timestamptz", "\"InvoiceSummary\""]
    let mangledLong = buildMangledCSymbol("very_long_overloaded_procedure_name", longSig)
    check mangledLong.len <= 63
    check mangledLong == buildMangledCSymbol("very_long_overloaded_procedure_name", longSig)
    let mangledDiff = buildMangledCSymbol("very_long_overloaded_procedure_name", longSig[0 .. ^2] & @["date"])
    check mangledLong != mangledDiff

    check normalizeSqlTypeKey("integer") == normalizeSqlTypeKey("int4")
    check normalizeSqlTypeKey("bigint") == normalizeSqlTypeKey("int8")
    check normalizeSqlTypeKey("Text") == normalizeSqlTypeKey("text")
    check normalizeSqlTypeKey("double precision") == normalizeSqlTypeKey("float8")

  test "Extension metadata priority (.nimble < pgxext.json), .control rules & rendering":
    let tmpDir = getTempDir() / ("pgx_m2_meta_" & $getCurrentProcessId())
    createDir(tmpDir)
    try:
      var meta = initDefaultExtensionMeta("demo_ext")
      check meta.version == "0.1.0"
      check meta.relocatable
      check not meta.trusted

      writeFile(tmpDir / "demo_ext.nimble", "version = \"0.2.3\"\ndescription = \"Custom Nimble Desc\"\n")
      check applyNimbleMeta(tmpDir, meta)
      check meta.version == "0.2.3"
      check meta.comment == "Custom Nimble Desc"

      writeFile(tmpDir / "pgxext.json", """{
        "version": "0.4.0",
        "comment": "Override JSON Desc",
        "trusted": true,
        "schema": "custom_ns",
        "requires": ["plpgsql", "pg_trgm"]
      }""")
      check applyPgxExtJson(tmpDir, meta)
      let errOk = finalizeAndValidateMeta(meta)
      check errOk == ""
      check meta.version == "0.4.0"
      check meta.comment == "Override JSON Desc"
      check meta.trusted
      check not meta.relocatable  # automatically false when schema is set
      check meta.schema == "custom_ns"
      check meta.requires == @["plpgsql", "pg_trgm"]

      let ctrl = renderControlFile(meta)
      check "default_version = '0.4.0'" in ctrl
      check "relocatable = false" in ctrl
      check "trusted = true" in ctrl
      check "schema = 'custom_ns'" in ctrl
      check "requires = 'plpgsql, pg_trgm'" in ctrl

      # Explicit schema + relocatable = true must be rejected cleanly
      var badMeta = initDefaultExtensionMeta("bad_ext")
      badMeta.schema = "locked_ns"
      badMeta.relocatable = true
      badMeta.hasExplicitRelocatable = true
      check "relocatable = true" in finalizeAndValidateMeta(badMeta)

      # Unsafe version and searchPath validation
      var badVer = initDefaultExtensionMeta("bad_ver")
      badVer.version = "0.1--0.2"
      check finalizeAndValidateMeta(badVer).len > 0

      let (_, spErr) = validateSafeIdentList("public; DROP TABLE users", "searchPath")
      check spErr.len > 0
      let (spOk, spNoErr) = validateSafeIdentList("public, pg_catalog, $user, pg_temp", "searchPath")
      check spNoErr == ""
      check spOk == @["public", "pg_catalog", "\"$user\"", "pg_temp"]
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)

  test "Structured schema snapshot diffing generates safe SQL migrations":
    let snap1 = SchemaSnapshot(
      version: "0.1.0",
      enums: @[EnumSchema(name: "Status", labels: @["draft", "active"])],
      composites: @[CompositeSchema(name: "OrderRow", fields: @[
        CompositeFieldSchema(name: "id", sqlType: "int8")
      ])],
      baseTypes: @[],
      routines: @[
        RoutineSchema(sigKey: "f(int4)", ddl: "CREATE OR REPLACE FUNCTION f(int4) returns Text as 'ext', 'pgx_f' language c IMMUTABLE STRICT;")
      ]
    )
    let snap2 = SchemaSnapshot(
      version: "0.2.0",
      enums: @[
        EnumSchema(name: "Status", labels: @["draft", "active", "settled"]),
        EnumSchema(name: "Priority", labels: @["low", "high"])
      ],
      composites: @[CompositeSchema(name: "OrderRow", fields: @[
        CompositeFieldSchema(name: "id", sqlType: "int8"),
        CompositeFieldSchema(name: "note", sqlType: "Text")
      ])],
      baseTypes: @[],
      routines: @[
        RoutineSchema(sigKey: "f(int4)", ddl: "CREATE OR REPLACE FUNCTION f(int4) returns Text as 'ext', 'pgx_f__int4' language c IMMUTABLE STRICT;"),
        RoutineSchema(sigKey: "f(text)", ddl: "CREATE OR REPLACE FUNCTION f(Text) returns Text as 'ext', 'pgx_f__text' language c IMMUTABLE STRICT;")
      ]
    )

    let rt = jsonToSnapshot(snapshotToJson(snap2))
    check rt.version == "0.2.0"
    check rt.enums.len == 2
    check rt.composites[0].fields.len == 2

    let mig = diffSnapshotsAndBuildMigration(snap1, snap2)
    check "ALTER TYPE \"Status\" ADD VALUE IF NOT EXISTS 'settled';" in mig
    check "CREATE TYPE \"Priority\" AS ENUM ('low', 'high');" in mig
    check "ALTER TYPE \"OrderRow\" ADD ATTRIBUTE \"note\" Text;" in mig
    check "pgx_f__int4" in mig
    check "pgx_f__text" in mig

  test "Recursive source hashing, non-destructive staging, and migration preservation on clean":
    let tmpDir = getTempDir() / ("pgx_m2_hash_" & $getCurrentProcessId())
    createDir(tmpDir / "src" / "sub")
    createDir(tmpDir / "private")
    createDir(tmpDir / "migrations")
    try:
      writeFile(tmpDir / "src" / "main.nim", "import sub/helper\n")
      writeFile(tmpDir / "src" / "sub" / "helper.nim", "proc h*(): int = 1\n")
      writeFile(tmpDir / "private" / "priv.nim", "proc p*(): int = 2\n")
      writeFile(tmpDir / "pgxext.json", "{\"version\": \"0.1.0\"}\n")
      writeFile(tmpDir / "migrations" / "demo--0.1.0--0.2.0.sql", "-- manual migration\n")

      let h0 = computeSourceHash(tmpDir)
      writeFile(tmpDir / "src" / "sub" / "helper.nim", "proc h*(): int = 99\n")
      let h1 = computeSourceHash(tmpDir)
      check h1 != h0

      writeFile(tmpDir / "private" / "priv.nim", "proc p*(): int = 88\n")
      let h2 = computeSourceHash(tmpDir)
      check h2 != h1

      writeFile(tmpDir / "pgxext.json", "{\"version\": \"0.2.0\"}\n")
      let h3 = computeSourceHash(tmpDir)
      check h3 != h2

      writeFile(tmpDir / "migrations" / "demo--0.1.0--0.2.0.sql", "-- updated migration\n")
      let h4 = computeSourceHash(tmpDir)
      check h4 != h3

      let staged = stageProjectSources(tmpDir, tmpDir / ".pgx_build" / "staged_src")
      check fileExists(staged.stagedMain)
      check fileExists(staged.stagedSrc / "sub" / "helper.nim")
      check fileExists(staged.stagedPrivate / "priv.nim")
      # Mutating staged copy never alters original user source
      writeFile(staged.stagedMain, "MUTATED")
      check readFile(tmpDir / "src" / "main.nim") == "import sub/helper\n"

      # cleanupGeneratedFiles cleans src/*.sql & staged_src but preserves migrations/*.sql
      writeFile(tmpDir / "src" / "demo--0.2.0.sql", "-- generated")
      cleanupGeneratedFiles(tmpDir / "src", "demo", tmpDir / "src" / "tmp_main.nim")
      check not fileExists(tmpDir / "src" / "demo--0.2.0.sql")
      check not dirExists(tmpDir / ".pgx_build" / "staged_src")
      check fileExists(tmpDir / "migrations" / "demo--0.1.0--0.2.0.sql")
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)
