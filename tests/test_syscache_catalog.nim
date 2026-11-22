import std/[strutils, unittest]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

{.emit: """
#include "fmgr.h"
#include "funcapi.h"
#include "catalog/pg_proc_d.h"
#include "catalog/pg_type_d.h"
#include "utils/elog.h"
#include "utils/syscache.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#undef sprintf
#undef vsprintf
#undef snprintf
#undef vsnprintf
#undef strerror
int pg_sprintf(char *str, const char *fmt, ...) {
  va_list args; va_start(args, fmt);
  int r = vsprintf(str, fmt, args);
  va_end(args); return r;
}
int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
  va_list args; va_start(args, fmt);
  int r = vsnprintf(str, count, fmt, args);
  va_end(args); return r;
}
int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
  return vsnprintf(str, count, fmt, args);
}
char *pg_strerror(int errnum) { return strerror(errnum); }

sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;

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
void *palloc(Size size) { return malloc(size ? size : 1); }
void *palloc0(Size size) { return calloc(1, size ? size : 1); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size ? size : 1); }
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void pfree(void *ptr) { if (ptr) free(ptr); }

/* Mock capture globals for SearchSysCache4 and SysCacheGetAttr */
static int pgx_mock_sc_cache_id = -1;
static Datum pgx_mock_k1 = 0, pgx_mock_k2 = 0, pgx_mock_k3 = 0, pgx_mock_k4 = 0;
static HeapTupleData pgx_mock_tup_storage;
static bool pgx_mock_force_null = false;
static NameData pgx_mock_proc_name = { .data = "v30_demo_fn" };
static NameData pgx_mock_type_name = { .data = "int4" };
static oidvector *pgx_mock_oidvec = NULL;
static int pgx_mock_text_derefs = 0;

static void pgx_init_mock_catalog(void) {
  if (!pgx_mock_oidvec) {
    pgx_mock_oidvec = (oidvector *)calloc(1, sizeof(oidvector) + 2 * sizeof(Oid));
    pgx_mock_oidvec->ndim = 1;
    pgx_mock_oidvec->dim1 = 2;
    pgx_mock_oidvec->lbound1 = 1;
    pgx_mock_oidvec->elemtype = OIDOID;
    pgx_mock_oidvec->values[0] = INT4OID;
    pgx_mock_oidvec->values[1] = TEXTOID;
  }
}

void pgx_set_mock_force_null(bool v) { pgx_mock_force_null = v; }
void pgx_reset_text_derefs(void) { pgx_mock_text_derefs = 0; }
int pgx_get_text_derefs(void) { return pgx_mock_text_derefs; }
int pgx_get_mock_sc_cache(void) { return pgx_mock_sc_cache_id; }
Datum pgx_get_mock_k1(void) { return pgx_mock_k1; }
Datum pgx_get_mock_k2(void) { return pgx_mock_k2; }
Datum pgx_get_mock_k3(void) { return pgx_mock_k3; }
Datum pgx_get_mock_k4(void) { return pgx_mock_k4; }
HeapTuple pgx_get_mock_tup(void) { pgx_init_mock_catalog(); return &pgx_mock_tup_storage; }

HeapTuple SearchSysCache4(int cacheId, Datum key1, Datum key2, Datum key3, Datum key4) {
  pgx_init_mock_catalog();
  pgx_mock_sc_cache_id = cacheId;
  pgx_mock_k1 = key1;
  pgx_mock_k2 = key2;
  pgx_mock_k3 = key3;
  pgx_mock_k4 = key4;
  return &pgx_mock_tup_storage;
}

Datum SysCacheGetAttr(int cacheId, HeapTuple tup, AttrNumber attributeNumber, bool *isNull) {
  pgx_init_mock_catalog();
  (void)tup;
  if (pgx_mock_force_null) {
    *isNull = true;
    return (Datum)0;
  }
  *isNull = false;
  if (cacheId == PROCOID) {
    if (attributeNumber == Anum_pg_proc_proretset) return BoolGetDatum(true);
    if (attributeNumber == Anum_pg_proc_prosrc) return CStringGetDatum("pgx_v30_demo_fn");
    if (attributeNumber == Anum_pg_proc_proname) return NameGetDatum(&pgx_mock_proc_name);
    if (attributeNumber == Anum_pg_proc_prokind) return CharGetDatum('f');
    if (attributeNumber == Anum_pg_proc_proisstrict) return BoolGetDatum(true);
    if (attributeNumber == Anum_pg_proc_pronargs) return Int16GetDatum(2);
    if (attributeNumber == Anum_pg_proc_pronargdefaults) return Int16GetDatum(1);
    if (attributeNumber == Anum_pg_proc_prorettype) return ObjectIdGetDatum(INT4OID);
    if (attributeNumber == Anum_pg_proc_proargnames) return CStringGetDatum("mock_argnames");
    if (attributeNumber == Anum_pg_proc_proargtypes) return PointerGetDatum(pgx_mock_oidvec);
  } else if (cacheId == TYPEOID) {
    if (attributeNumber == Anum_pg_type_oid) return ObjectIdGetDatum(INT4OID);
    if (attributeNumber == Anum_pg_type_typname) return NameGetDatum(&pgx_mock_type_name);
    if (attributeNumber == Anum_pg_type_typowner) return ObjectIdGetDatum((Oid)10);
    if (attributeNumber == Anum_pg_type_typlen) return Int16GetDatum(4);
    if (attributeNumber == Anum_pg_type_typtype) return CharGetDatum('b');
    if (attributeNumber == Anum_pg_type_typarray) return ObjectIdGetDatum(INT4ARRAYOID);
    if (attributeNumber == Anum_pg_type_typndims) return Int32GetDatum(0);
    if (attributeNumber == Anum_pg_type_typdefault) return CStringGetDatum("42");
  }
  return (Datum)0;
}

void ReleaseSysCache(HeapTuple tuple) { (void)tuple; }

char *text_to_cstring(const text *t) {
  pgx_mock_text_derefs++;
  if (t == NULL) abort();
  return strdup((const char *)t);
}

int get_func_input_arg_names(Datum proargnames, Datum proargmodes, char ***arg_names) {
  (void)proargmodes;
  if (proargnames == 0) return 0;
  char **arr = (char **)malloc(2 * sizeof(char *));
  arr[0] = (char *)"x";
  arr[1] = (char *)"label";
  *arg_names = arr;
  return 2;
}
""".}

import ../src/pgxcrown/datatypes/basic
import ../src/pgxcrown/datatypes/heaptuples
import ../src/pgxcrown/syscache
import ../src/pgxcrown/catalog/pg_proc
import ../src/pgxcrown/catalog/pg_type
import ../src/pgxcrown/hooks/emit_hook

proc pgx_set_mock_force_null(v: bool) {.importc.}
proc pgx_reset_text_derefs() {.importc.}
proc pgx_get_text_derefs(): cint {.importc.}
proc pgx_get_mock_sc_cache(): cint {.importc.}
proc pgx_get_mock_k1(): Datum {.importc.}
proc pgx_get_mock_k2(): Datum {.importc.}
proc pgx_get_mock_k3(): Datum {.importc.}
proc pgx_get_mock_k4(): Datum {.importc.}
proc pgx_get_mock_tup(): HeapTuple {.importc.}

suite "Pgxcrown - SysCache, Catalog Null-Safety & EmitHook Export Suite":

  test "SearchSysCache4 forwards all 4 Datum keys and HeapTupleIsValid handles nil":
    let t = SearchSysCache4(
      AMOPSTRATEGY,
      Datum(1001),
      Datum(2002),
      Datum(3003),
      Datum(4004)
    )
    check HeapTupleIsValid(t)
    check not HeapTupleIsValid(nil)
    check pgx_get_mock_sc_cache() == AMOPSTRATEGY
    check pgx_get_mock_k1() == Datum(1001)
    check pgx_get_mock_k2() == Datum(2002)
    check pgx_get_mock_k3() == Datum(3003)
    check pgx_get_mock_k4() == Datum(4004)
    ReleaseSysCache(t)

  test "pg_proc and pg_type extractors read valid values accurately":
    pgx_set_mock_force_null(false)
    let tup = pgx_get_mock_tup()

    check get_pg_proc_retset(tup) == true
    check $get_pg_proc_src(tup) == "pgx_v30_demo_fn"
    check $get_pg_proc_name(tup) == "v30_demo_fn"
    check get_pg_proc_kind(tup) == 'f'
    check get_pg_proc_is_strict(tup) == true
    check get_pg_proc_nargs(tup) == 2'i16
    check get_pg_proc_default_nargs(tup) == 1'i16
    check get_pg_proc_rettype(tup) == 23.Oid
    check get_pg_proc_argnames(tup) == @["x", "label"]
    let argTypes = get_pg_proc_argtypes(tup)
    check argTypes != nil
    check argTypes[0] == 23.Oid
    check argTypes[1] == 25.Oid
    check get_pg_proc_arg_oid(tup, 0) == 23.Oid
    check get_pg_proc_arg_oid(tup, 1) == 25.Oid
    # Bounds safety on oidvector
    check get_pg_proc_arg_oid(tup, -1) == 0.Oid
    check get_pg_proc_arg_oid(tup, 2) == 0.Oid

    check get_pg_type_oid(tup) == 23.Oid
    check $get_pg_type_name(tup) == "int4"
    check get_pg_type_owner(tup) == 10.Oid
    check get_pg_type_len(tup) == 4'i16
    check get_pg_type_type(tup) == 'b'
    check get_pg_type_array(tup) == 1007.Oid
    check get_pg_type_ndims(tup) == 0'i32
    check $get_pg_type_defaultvalue(tup) == "42"

  test "pg_proc and pg_type extractors never dereference NULL attributes or nil tuples":
    pgx_set_mock_force_null(true)
    pgx_reset_text_derefs()
    let tup = pgx_get_mock_tup()

    check get_pg_proc_retset(tup) == false
    check get_pg_proc_src(tup) == nil
    check get_pg_proc_name(tup) == nil
    check get_pg_proc_kind(tup) == '\0'
    check get_pg_proc_is_strict(tup) == false
    check get_pg_proc_nargs(tup) == 0'i16
    check get_pg_proc_default_nargs(tup) == 0'i16
    check get_pg_proc_rettype(tup) == 0.Oid
    check get_pg_proc_argnames(tup).len == 0
    check get_pg_proc_argtypes(tup) == nil
    check get_pg_proc_arg_oid(tup, 0) == 0.Oid

    check get_pg_type_oid(tup) == 0.Oid
    check get_pg_type_name(tup) == nil
    check get_pg_type_owner(tup) == 0.Oid
    check get_pg_type_len(tup) == 0'i16
    check get_pg_type_type(tup) == '\0'
    check get_pg_type_array(tup) == 0.Oid
    check get_pg_type_ndims(tup) == 0'i32
    check get_pg_type_defaultvalue(tup) == nil
    check pgx_get_text_derefs() == 0

    let nilTup: HeapTuple = nil
    check get_pg_proc_src(nilTup) == nil
    check get_pg_proc_name(nilTup) == nil
    check get_pg_proc_argtypes(nilTup) == nil
    check get_pg_proc_arg_oid(nilTup, 0) == 0.Oid
    check get_pg_proc_argnames(nilTup).len == 0
    check get_pg_type_name(nilTup) == nil
    check get_pg_type_defaultvalue(nilTup) == nil
    check pgx_get_text_derefs() == 0

  test "Templates evaluate tuple expressions at most once":
    pgx_set_mock_force_null(false)
    var evals = 0
    proc fetchTup(counter: var int): HeapTuple =
      inc counter
      pgx_get_mock_tup()
    check $get_pg_type_name(fetchTup(evals)) == "int4"
    check get_pg_proc_arg_oid(fetchTup(evals), 1) == 25.Oid
    check evals == 2

  test "emit_hook ErrorData fields are exported for inspection and mutation":
    var ed: ErrorData
    ed.elevel = 20
    ed.sqlerrcode = 12345
    ed.output_to_server = true
    ed.output_to_client = false
    ed.hide_stmt = true
    ed.hide_ctx = true
    ed.message = "custom error".cstring
    ed.detail = "detail msg".cstring
    ed.detail_log = "log msg".cstring
    ed.hint = "hint msg".cstring
    ed.context = "ctx msg".cstring
    ed.schema_name = "public".cstring
    ed.table_name = "users".cstring
    ed.column_name = "id".cstring
    ed.datatype_name = "int4".cstring
    ed.constraint_name = "users_pkey".cstring
    ed.lineno = 99
    check ed.elevel == 20
    check ed.sqlerrcode == 12345
    check ed.output_to_server
    check not ed.output_to_client
    check $ed.message == "custom error"
    check $ed.detail == "detail msg"
    check $ed.hint == "hint msg"
    check $ed.schema_name == "public"
    check ed.lineno == 99
