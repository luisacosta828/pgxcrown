import std/[unittest, options, json, strutils, math, typetraits]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif
#include "fmgr.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "utils/builtins.h"
#include "utils/array.h"
#include "utils/jsonb.h"
#include "utils/snapmgr.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "catalog/pg_type_d.h"
""" .}

{.emit: """
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

static int mock_palloc_cnt = 0;
static int mock_pfree_cnt = 0;
static void *mock_detoast_trigger_ptr = NULL;
static void *mock_detoast_allocated_copy = NULL;
static int mock_detoast_copy_freed = 0;
static void *mock_outfunc_cstring = NULL;
static int mock_outfunc_cstring_freed = 0;

void mock_reset_stats(void) {
  mock_palloc_cnt = 0;
  mock_pfree_cnt = 0;
  mock_detoast_trigger_ptr = NULL;
  mock_detoast_allocated_copy = NULL;
  mock_detoast_copy_freed = 0;
  mock_outfunc_cstring = NULL;
  mock_outfunc_cstring_freed = 0;
}
int mock_get_detoast_copy_freed(void) { return mock_detoast_copy_freed; }
int mock_get_outfunc_freed(void) { return mock_outfunc_cstring_freed; }

void *palloc(Size size) {
  mock_palloc_cnt++;
  return malloc(size ? size : 1);
}
void *palloc0(Size size) {
  mock_palloc_cnt++;
  return calloc(1, size ? size : 1);
}
void pfree(void *ptr) {
  if (ptr == NULL) return;
  mock_pfree_cnt++;
  if (ptr == mock_detoast_allocated_copy) {
    mock_detoast_copy_freed++;
    mock_detoast_allocated_copy = NULL;
  }
  if (ptr == mock_outfunc_cstring) {
    mock_outfunc_cstring_freed++;
    mock_outfunc_cstring = NULL;
  }
  free(ptr);
}
char *pstrdup(const char *in) {
  if (!in) return NULL;
  size_t n = strlen(in) + 1;
  char *out = (char *)palloc(n);
  memcpy(out, in, n);
  return out;
}

void *mock_alloc_varlena(const void *s, int len, bool mark_as_toast_trigger) {
  text *t = (text *)palloc(VARHDRSZ + (size_t)len);
  SET_VARSIZE(t, VARHDRSZ + (size_t)len);
  if (len > 0 && s != NULL) memcpy(VARDATA(t), s, (size_t)len);
  if (mark_as_toast_trigger) {
    mock_detoast_trigger_ptr = (void *)t;
  }
  return (void *)t;
}

struct varlena *pg_detoast_datum_packed(struct varlena *datum) {
  if ((void *)datum != NULL && (void *)datum == mock_detoast_trigger_ptr) {
    int sz = VARSIZE_ANY(datum);
    void *copy = palloc((Size)sz);
    memcpy(copy, datum, (size_t)sz);
    mock_detoast_allocated_copy = copy;
    return (struct varlena *)copy;
  }
  return datum;
}

void getTypeOutputInfo(Oid type, Oid *typOutput, bool *typIsVarlena) {
  *typIsVarlena = false;
  if (type == 99991) {
    *typOutput = 88881;
  } else {
    *typOutput = InvalidOid;
  }
}

char *OidOutputFunctionCall(Oid functionId, Datum val) {
  if (functionId == 88881) {
    char buf[64];
    snprintf(buf, sizeof(buf), "oid_out:%lld", (long long)DatumGetInt64(val));
    mock_outfunc_cstring = (void *)pstrdup(buf);
    return (char *)mock_outfunc_cstring;
  }
  return NULL;
}

void get_typlenbyvalalign(Oid typid, int16 *typlen, bool *typbyval, char *typalign) {
  if (typid == INT4OID) {
    *typlen = 4; *typbyval = true; *typalign = 'i';
  } else if (typid == TEXTOID) {
    *typlen = -1; *typbyval = false; *typalign = 'i';
  } else {
    *typlen = 8; *typbyval = true; *typalign = 'd';
  }
}

/* Mock ArrayType layout sufficient for DatumGetArrayTypeP + deconstruct_array */
typedef struct MockArrayHeader {
  int32 vl_len_;
  int ndim;
  int32 dataoffset;
  Oid elemtype;
  int nelems;
  Datum *elems;
  bool *nulls;
} MockArrayHeader;

static MockArrayHeader *mock_arr_header = NULL;

void *mock_create_int4_array(const int32 *vals, int count) {
  MockArrayHeader *hdr = (MockArrayHeader *)palloc0(sizeof(MockArrayHeader));
  SET_VARSIZE(hdr, sizeof(MockArrayHeader));
  hdr->ndim = count > 0 ? 1 : 0;
  hdr->elemtype = INT4OID;
  hdr->nelems = count;
  hdr->elems = (Datum *)palloc(sizeof(Datum) * (size_t)(count > 0 ? count : 1));
  hdr->nulls = (bool *)palloc0(sizeof(bool) * (size_t)(count > 0 ? count : 1));
  for (int i = 0; i < count; i++) {
    hdr->elems[i] = Int32GetDatum(vals[i]);
  }
  mock_arr_header = hdr;
  return (void *)hdr;
}

void *mock_create_opt_text_array(char **vals, bool *is_nulls, int count) {
  MockArrayHeader *hdr = (MockArrayHeader *)palloc0(sizeof(MockArrayHeader));
  SET_VARSIZE(hdr, sizeof(MockArrayHeader));
  hdr->ndim = count > 0 ? 1 : 0;
  hdr->elemtype = TEXTOID;
  hdr->nelems = count;
  hdr->elems = (Datum *)palloc(sizeof(Datum) * (size_t)(count > 0 ? count : 1));
  hdr->nulls = (bool *)palloc0(sizeof(bool) * (size_t)(count > 0 ? count : 1));
  for (int i = 0; i < count; i++) {
    if (is_nulls[i]) {
      hdr->elems[i] = (Datum)0;
      hdr->nulls[i] = true;
    } else {
      const char *s = vals[i];
      hdr->elems[i] = PointerGetDatum(mock_alloc_varlena(s, (int)strlen(s), false));
      hdr->nulls[i] = false;
    }
  }
  mock_arr_header = hdr;
  return (void *)hdr;
}

struct varlena *pg_detoast_datum(struct varlena *datum) {
  return datum;
}

void deconstruct_array(ArrayType *array, Oid elmtype, int elmlen, bool elmbyval, char elmalign,
                       Datum **elemsp, bool **nullsp, int *nelemsp) {
  MockArrayHeader *hdr = (MockArrayHeader *)array;
  *nelemsp = hdr->nelems;
  if (hdr->nelems <= 0) {
    *elemsp = NULL;
    *nullsp = NULL;
    return;
  }
  *elemsp = (Datum *)palloc(sizeof(Datum) * (size_t)hdr->nelems);
  *nullsp = (bool *)palloc(sizeof(bool) * (size_t)hdr->nelems);
  memcpy(*elemsp, hdr->elems, sizeof(Datum) * (size_t)hdr->nelems);
  memcpy(*nullsp, hdr->nulls, sizeof(bool) * (size_t)hdr->nelems);
}

/* Stubs for PostgreSQL server symbols pulled by debug-mode compilation units */
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

MemoryContext AllocSetContextCreateInternal(MemoryContext parent, const char *name, Size minContextSize, Size initBlockSize, Size maxBlockSize) {
  (void)parent; (void)name; (void)minContextSize; (void)initBlockSize; (void)maxBlockSize;
  return NULL;
}
void MemoryContextDelete(MemoryContext context) { (void)context; }

text *cstring_to_text(const char *s) {
  int n = s ? (int)strlen(s) : 0;
  return (text *)mock_alloc_varlena(s, n, false);
}
text *cstring_to_text_with_len(const char *s, int len) {
  return (text *)mock_alloc_varlena(s, len, false);
}

Datum DirectFunctionCall1Coll(PGFunction func, Oid collation, Datum arg1) { (void)func; (void)collation; (void)arg1; return (Datum)0; }
Datum DirectFunctionCall2Coll(PGFunction func, Oid collation, Datum arg1, Datum arg2) { (void)func; (void)collation; (void)arg1; (void)arg2; return (Datum)0; }
Datum DirectFunctionCall3Coll(PGFunction func, Oid collation, Datum arg1, Datum arg2, Datum arg3) { (void)func; (void)collation; (void)arg1; (void)arg2; (void)arg3; return (Datum)0; }

Datum numeric_in(PG_FUNCTION_ARGS) { return (Datum)0; }
Datum numeric_out(PG_FUNCTION_ARGS) { return (Datum)0; }
bool numeric_is_nan(Numeric num) { (void)num; return false; }
bool numeric_is_inf(Numeric num) { (void)num; return false; }
Datum numeric_cmp(PG_FUNCTION_ARGS) { return Int32GetDatum(0); }
Datum numeric_float8(PG_FUNCTION_ARGS) { return Float8GetDatum(0.0); }
Datum numeric_int8(PG_FUNCTION_ARGS) { return Int64GetDatum(0); }
Datum enum_out(PG_FUNCTION_ARGS) { return (Datum)0; }
Datum jsonb_in(PG_FUNCTION_ARGS) { return (Datum)0; }

JsonbIterator *JsonbIteratorInit(JsonbContainer *container) { (void)container; return NULL; }
JsonbIteratorToken JsonbIteratorNext(JsonbIterator **it, JsonbValue *val, bool skipNested) { (void)it; (void)val; (void)skipNested; return WJB_DONE; }

ArrayType *construct_array(Datum *elems, int nelems, Oid elmtype, int elmlen, bool elmbyval, char elmalign) {
  (void)elems; (void)nelems; (void)elmtype; (void)elmlen; (void)elmbyval; (void)elmalign;
  return NULL;
}

uint64 SPI_processed = 0;
SPITupleTable *SPI_tuptable = NULL;
int SPI_result = 0;
static int mock_freeplan_calls = 0;
int mock_get_freeplan_calls(void) { return mock_freeplan_calls; }

int SPI_connect(void) { return SPI_OK_CONNECT; }
int SPI_finish(void) { return SPI_OK_FINISH; }
int SPI_execute_plan(SPIPlanPtr plan, Datum *Values, const char *Nulls, bool read_only, long count) {
  (void)plan; (void)Values; (void)Nulls; (void)read_only; (void)count;
  return SPI_OK_SELECT;
}
Portal SPI_cursor_open_with_args(const char *name, const char *src, int nargs, Oid *argtypes, Datum *Values, const char *Nulls, bool read_only, int cursorOptions) {
  (void)name; (void)src; (void)nargs; (void)argtypes; (void)Values; (void)Nulls; (void)read_only; (void)cursorOptions;
  return NULL;
}
void SPI_cursor_fetch(Portal portal, bool forward, long count) { (void)portal; (void)forward; (void)count; }
void SPI_cursor_close(Portal portal) { (void)portal; }
int SPI_freeplan(SPIPlanPtr plan) {
  if (plan != NULL) mock_freeplan_calls++;
  return 0;
}
void SPI_freetuptable(SPITupleTable *tuptable) { (void)tuptable; }
Datum SPI_getbinval(HeapTuple tuple, TupleDesc tupdesc, int fnumber, bool *isnull) {
  (void)tuple; (void)tupdesc; (void)fnumber;
  if (isnull) *isnull = true;
  return (Datum)0;
}
const char *SPI_result_code_string(int code) { (void)code; return "MOCK_SPI_CODE"; }
bool ActiveSnapshotSet(void) { return false; }
Snapshot GetActiveSnapshot(void) { return NULL; }
CommandId GetCurrentCommandId(bool used) { (void)used; return 0; }
""".}

import pgxcrown

proc mockResetStats() {.importc: "mock_reset_stats", nodecl, cdecl.}
proc mockGetDetoastCopyFreed(): cint {.importc: "mock_get_detoast_copy_freed", nodecl, cdecl.}
proc mockGetOutfuncFreed(): cint {.importc: "mock_get_outfunc_freed", nodecl, cdecl.}
proc mockGetFreeplanCalls(): cint {.importc: "mock_get_freeplan_calls", nodecl, cdecl.}
proc mockAllocVarlena(s: pointer, len: cint, markTrigger: bool): pointer {.importc: "mock_alloc_varlena", nodecl, cdecl.}
proc mockCreateInt4Array(vals: ptr int32, count: cint): pointer {.importc: "mock_create_int4_array", nodecl, cdecl.}
proc mockCreateOptTextArray(vals: ptr cstring, nulls: ptr bool, count: cint): pointer {.importc: "mock_create_opt_text_array", nodecl, cdecl.}

proc makeTextDatum(s: string, triggerDetoastCopy: bool = false): Datum =
  let p = mockAllocVarlena(if s.len > 0: unsafeAddr s[0] else: nil, cint(s.len), triggerDetoastCopy)
  Datum(cast[uint64](cast[uint](p)))

proc makeByteaDatum(data: openArray[byte]): Datum =
  let p = mockAllocVarlena(if data.len > 0: unsafeAddr data[0] else: nil, cint(data.len), false)
  Datum(cast[uint64](cast[uint](p)))

# External plugin type + pgxFromDatum extensibility hook
type
  PluginTag = object
    label: string

proc pgxFromDatum(d: Datum, _: typedesc[PluginTag]): PluginTag =
  let s = datumToNim[string](d, TEXTOID, false)
  PluginTag(label: "plugin:" & s)

type
  TestRole = enum
    trAdmin = "admin"
    trViewer = "viewer"

  AccountId = distinct int64
  EmailAddr = distinct string

  MockInsertRow = object
    name: string
    age: int32
    active: bool

  MockBatchRow = object
    title: string
    score: int64

suite "SPI Binary v2 - Pure Nim Parameterized QueryBuilder ($1..$N)":
  test "Sequential $1..$N across WHERE, AND, OR and backward-compatible $q":
    let u = table("users", "u")
    let q = Select(u.id, u.name)
      .From(u)
      .Where(u.id == 42 and (u.name == "Alice" or u.role == trAdmin))
      .OrderBy(u.id.asc)
      .Limit(10)

    # Legacy literal rendering intact
    check $q == "SELECT \"u\".\"id\", \"u\".\"name\"\nFROM \"users\" \"u\"\nWHERE \"u\".\"id\" = 42 AND (\"u\".\"name\" = 'Alice' OR \"u\".\"role\" = 'admin')\nORDER BY \"u\".\"id\" ASC\nLIMIT 10"

    let pq = toParameterizedSql(q)
    check pq.sql == "SELECT \"u\".\"id\", \"u\".\"name\"\nFROM \"users\" \"u\"\nWHERE \"u\".\"id\" = $1 AND (\"u\".\"name\" = $2 OR \"u\".\"role\" = $3)\nORDER BY \"u\".\"id\" ASC\nLIMIT 10"
    check pq.params.len == 3
    check pq.params[0].kind == bpInt4
    check pq.params[0].int4Val == 42'i32
    check pq.params[1].kind == bpText
    check pq.params[1].textVal == "Alice"
    check pq.params[2].kind == bpText
    check pq.params[2].textVal == "admin"

  test "Renumbering across WithCte, AndWith, CaseWhen, Join, LeftJoinLateral, Having, Between, In, Like, Option none":
    let u = table("users", "u")
    let o = table("orders", "o")

    let cte1 = Select(u.id, u.name).From(u).Where(u.country == "US")
    let cte2 = Select(o.user_id, sum(o.amount).as("total"))
      .From(o)
      .GroupBy(o.user_id)
      .Having(sum(o.amount) > 100)
    let subLat = Select(o.id).From(o).Where(o.status == "paid").Limit(1)
    let inSub = Select(o.user_id).From(o).Where(o.note == "vip")

    let tierExpr = caseWhen(u.score >= 90).then("gold")
      .`when`(u.score >= 50).then(10)
      .elseEnd("std")

    let q = WithCte("active_users", cte1)
      .AndWith("order_totals", cte2)
      .Select(u.id, tierExpr.as("tier"))
      .From("active_users", "u")
      .InnerJoin("order_totals", "o").On(u.id == o.user_id and o.total >= 200)
      .LeftJoinLateral(subLat, "l").On("TRUE")
      .Where(
        u.age.between(18, 65) and
        u.tag.inList(["x", "y"]) and
        u.bio.like("%nim%") and
        u.deleted_at == none(string) and
        inSubquery(u.id, inSub)
      )

    let pq = toParameterizedSql(q)
    # Verify sequential numbering $1 .. $15 with zero gaps or duplicates
    for i in 1 .. 15:
      check ("$" & $i) in pq.sql
    check not ("$16" in pq.sql)
    check "IS NULL" in pq.sql
    check pq.params.len == 15
    check pq.params[0].textVal == "US"
    check pq.params[1].int4Val == 100'i32
    check pq.params[2].int4Val == 90'i32
    check pq.params[3].textVal == "gold"
    check pq.params[4].int4Val == 50'i32
    check pq.params[5].int4Val == 10'i32
    check pq.params[6].textVal == "std"
    check pq.params[7].int4Val == 200'i32
    check pq.params[8].textVal == "paid"
    check pq.params[9].int4Val == 18'i32
    check pq.params[10].int4Val == 65'i32
    check pq.params[11].textVal == "x"
    check pq.params[12].textVal == "y"
    check pq.params[13].textVal == "%nim%"
    check pq.params[14].textVal == "vip"

  test "Verify exact param order including subqueries, UNION, JSONB operators":
    let u = table("users", "u")
    let o = table("orders", "o")
    let subExists = Select(o.id).From(o).Where(o.user_id == u.id and o.kind == "refund")
    let q1 = Select(u.id).From(u).Where(u.data["category"] == "tech" and exists(subExists))
    let q2 = Select(u.id).From(u).Where(u.name == "Bob")
    let qUnion = q1.UnionAll(q2)

    let pq = toParameterizedSql(qUnion)
    check "\"u\".\"data\" -> 'category' = $1" in pq.sql
    check "EXISTS (SELECT \"o\".\"id\"\nFROM \"orders\" \"o\"\nWHERE \"o\".\"user_id\" = \"u\".\"id\" AND \"o\".\"kind\" = $2)" in pq.sql
    check "UNION ALL\nSELECT \"u\".\"id\"\nFROM \"users\" \"u\"\nWHERE \"u\".\"name\" = $3" in pq.sql
    check pq.params.len == 3
    check pq.params[0].textVal == "tech"
    check pq.params[1].textVal == "refund"
    check pq.params[2].textVal == "Bob"

  test "INSERT VALUES, insertFrom, insertManyFrom, UPDATE SET, ON CONFLICT DO UPDATE, DELETE WHERE":
    let u = table("users", "u")
    let insSingle = InsertInto("users", "name", "age").Values("Ada", 36).Returning("id")
    let pqIns = toParameterizedSql(insSingle)
    check pqIns.sql == "INSERT INTO \"users\" (\"name\", \"age\")\nVALUES\n  ($1, $2)\nRETURNING \"id\""
    check pqIns.params.len == 2
    check pqIns.params[0].textVal == "Ada"
    check pqIns.params[1].int4Val == 36'i32

    let insMulti = InsertInto("users", "name", "age").Values(Row("Ada", 36)).Values(Row("Grace", 85))
    let pqMulti = toParameterizedSql(insMulti)
    check pqMulti.sql == "INSERT INTO \"users\" (\"name\", \"age\")\nVALUES\n  ($1, $2),\n  ($3, $4)"
    check pqMulti.params.len == 4
    check pqMulti.params[0].textVal == "Ada"
    check pqMulti.params[1].int4Val == 36'i32
    check pqMulti.params[2].textVal == "Grace"
    check pqMulti.params[3].int4Val == 85'i32

    let ups = InsertInto("users", "email", "name")
      .Values("a@b.c", "Old")
      .OnConflict("email")
      .DoUpdate(u.name, "Target")
      .Returning("id")
    let pqUps = toParameterizedSql(ups)
    check pqUps.sql == "INSERT INTO \"users\" (\"email\", \"name\")\nVALUES\n  ($1, $2)\nON CONFLICT (\"email\") DO UPDATE SET \"name\" = $3\nRETURNING \"id\""
    check pqUps.params.len == 3
    check pqUps.params[2].textVal == "Target"

    let upsExpr = InsertInto("users", "email", "age")
      .Values("x@y.z", 10)
      .OnConflict("email")
      .DoUpdate(u.age == 99)
    let pqUpsExpr = toParameterizedSql(upsExpr)
    check pqUpsExpr.sql == "INSERT INTO \"users\" (\"email\", \"age\")\nVALUES\n  ($1, $2)\nON CONFLICT (\"email\") DO UPDATE SET \"age\" = $3"
    check pqUpsExpr.params.len == 3
    check pqUpsExpr.params[2].int4Val == 99'i32

    let upd = Update(u).Set(u.name, "NewName").Set(u.age, none(int32)).Where(u.id == 7).Returning("id")
    let pqUpd = toParameterizedSql(upd)
    check pqUpd.sql == "UPDATE \"users\"\nSET \"name\" = $1, \"age\" = $2\nWHERE \"u\".\"id\" = $3\nRETURNING \"id\""
    check pqUpd.params.len == 3
    check pqUpd.params[0].textVal == "NewName"
    check pqUpd.params[1].kind == bpNull
    check pqUpd.params[1].nullOidHint == 23'u32
    check pqUpd.params[2].int4Val == 7'i32

    let del = DeleteFrom(u).Where(u.name == "Gone").Returning("id")
    let pqDel = toParameterizedSql(del)
    check pqDel.sql == "DELETE FROM \"users\"\nWHERE \"u\".\"name\" = $1\nRETURNING \"id\""
    check pqDel.params.len == 1
    check pqDel.params[0].textVal == "Gone"

    let insObj = insertFrom(MockInsertRow(name: "Lin", age: 29, active: true), "users")
    let pqObj = toParameterizedSql(insObj)
    check pqObj.sql == "INSERT INTO \"users\" (\"name\", \"age\", \"active\")\nVALUES\n  ($1, $2, $3)"
    check pqObj.params.len == 3
    check pqObj.params[0].textVal == "Lin"
    check pqObj.params[1].int4Val == 29'i32
    check pqObj.params[2].boolVal == true

    let insMany = insertManyFrom(@[
      MockBatchRow(title: "T1", score: 100),
      MockBatchRow(title: "T2", score: 200)
    ], "batches")
    let pqMany = toParameterizedSql(insMany)
    check pqMany.sql == "INSERT INTO \"batches\" (\"title\", \"score\")\nVALUES\n  ($1, $2),\n  ($3, $4)"
    check pqMany.params.len == 4
    check pqMany.params[0].textVal == "T1"
    check pqMany.params[1].kind == bpInt8
    check pqMany.params[1].int8Val == 100'i64
    check pqMany.params[3].int8Val == 200'i64

    let insRaw = InsertInto("t", "j", "c", "v").Values(raw("'{\"a\":1}'::json"), raw("'green'::sb_color"), 42)
    let pqRaw = toParameterizedSql(insRaw)
    check pqRaw.sql == "INSERT INTO \"t\" (\"j\", \"c\", \"v\")\nVALUES\n  ('{\"a\":1}'::json, 'green'::sb_color, $1)"
    check pqRaw.params.len == 1
    check pqRaw.params[0].kind == bpInt4
    check pqRaw.params[0].int4Val == 42'i32

  test "Literal $1 payload immunity, SQL injection preservation, and NUL rejection":
    let u = table("users", "u")
    let payload = "$1; DROP TABLE users; --"
    let q = Select(u.id).From(u).Where(u.name == payload and u.bio == "$2 literal")
    let pq = toParameterizedSql(q)
    check pq.sql == "SELECT \"u\".\"id\"\nFROM \"users\" \"u\"\nWHERE \"u\".\"name\" = $1 AND \"u\".\"bio\" = $2"
    check pq.params.len == 2
    check pq.params[0].textVal == payload
    check pq.params[1].textVal == "$2 literal"

    expect ValueError:
      validateNoNullBytes("SELECT 'a\0b'")
    let badQ = Select(u.id).From(u).Where(u.name == "abc\0def")
    let pqBad = toParameterizedSql(badQ)
    check pqBad.params[0].textVal == "abc\0def"

  test "All BoundParam kinds (Option, Pg*, JsonNode, distinct, arrays)":
    let b = toPgBytea(@[byte 0x00, 0xAB, 0xFF])
    let uid = parsePgUuid("550e8400-e29b-41d4-a716-446655440000")
    let dt = PgDate(days: 8000'i32)
    let ts = PgTimestamp(usec: 123456789'i64)
    let tstz = PgTimestampTz(usec: 987654321'i64)
    let iv = PgInterval(usec: 5000000'i64, days: 2'i32, months: 3'i32)
    let num = pgNumeric("12345.6789")
    let j = %*{"k": "v"}

    check toBoundParam(none(string)).kind == bpNull
    check toBoundParam(none(string)).nullOidHint == 25'u32
    check toBoundParam(none(int32)).nullOidHint == 23'u32
    check toBoundParam(none(PgUuid)).nullOidHint == 2950'u32
    check toBoundParam(none(JsonNode)).nullOidHint == 3802'u32
    check toBoundParam(b).byteaVal == @[byte 0x00, 0xAB, 0xFF]
    check toBoundParam(uid).kind == bpUuid
    check toBoundParam(uid).uuidBytes == uid.bytes
    check toBoundParam(dt).dateDays == 8000'i32
    check toBoundParam(ts).tsUsec == 123456789'i64
    check toBoundParam(tstz).tstzUsec == 987654321'i64
    check toBoundParam(iv).ivDays == 2'i32
    check toBoundParam(iv).ivMonths == 3'i32
    check toBoundParam(num).numericLit == "12345.6789"
    check toBoundParam(j).jsonbVal["k"].getStr == "v"
    check toBoundParam(none(JsonNode)).kind == bpNull
    check toBoundParam(AccountId(99'i64)).int8Val == 99'i64
    check toBoundParam(EmailAddr("a@b.c")).textVal == "a@b.c"
    check toBoundParam(0x80000001'u32).kind == bpInt8
    check toBoundParam(0x80000001'u32).int8Val == 2147483649'i64
    check toBoundParam(@[1'i32, 2'i32]).int4Arr == @[1'i32, 2'i32]
    check toBoundParam(@[1'i64, 2'i64]).int8Arr == @[1'i64, 2'i64]
    check toBoundParam(@[1.5'f64, 2.5'f64]).float8Arr == @[1.5'f64, 2.5'f64]
    check toBoundParam(@[true, false]).boolArr == @[true, false]

suite "SPI Binary v2 - datumToNim Deserialization, Safety & Extensibility":
  test "Compile-time rejection of Datum and cstring in datumToNim":
    check not compiles(datumToNim[Datum](NullDatum, INT8OID, false))
    check not compiles(datumToNim[Option[Datum]](NullDatum, INT8OID, true))
    check not compiles(datumToNim[seq[Datum]](NullDatum, INT8ARRAYOID, true))
    check not compiles(datumToNim[cstring](NullDatum, TEXTOID, false))
    check not compiles(datumToNim[Option[cstring]](NullDatum, TEXTOID, true))

  test "NULL vs empty string bug fix with Option[T]":
    let emptyTxtD = makeTextDatum("")
    let nonEmptyTxtD = makeTextDatum("hello")

    # Empty string with isnull=false MUST return some(""), NOT none(string)
    let optEmpty = datumToNim[Option[string]](emptyTxtD, TEXTOID, false)
    check optEmpty.isSome
    check optEmpty.get == ""

    # NULL with isnull=true MUST return none(string)
    let optNull = datumToNim[Option[string]](NullDatum, TEXTOID, true)
    check optNull.isNone

    # Even if datum holds 0 or garbage when isnull=true, real isnull wins
    let optNullZero = datumToNim[Option[int32]](Int32GetDatum(0'i32), INT4OID, true)
    check optNullZero.isNone
    let optZero = datumToNim[Option[int32]](Int32GetDatum(0'i32), INT4OID, false)
    check optZero == some(0'i32)

    check datumToNim[Option[string]](nonEmptyTxtD, TEXTOID, false) == some("hello")

  test "Signed & unsigned integer binary extraction, widening, and bounds errors":
    check datumToNim[int64](Int16GetDatum(-7'i16), INT2OID, false) == -7'i64
    check datumToNim[int64](Int32GetDatum(123456'i32), INT4OID, false) == 123456'i64
    check datumToNim[int64](Int64GetDatum(high(int64)), INT8OID, false) == high(int64)
    check datumToNim[int32](Int16GetDatum(30000'i16), INT2OID, false) == 30000'i32
    check datumToNim[int16](Int64GetDatum(-32000'i64), INT8OID, false) == -32000'i16
    check datumToNim[int8](Int32GetDatum(127'i32), INT4OID, false) == 127'i8
    check datumToNim[uint8](Int16GetDatum(255'i16), INT2OID, false) == 255'u8
    check datumToNim[uint16](Int32GetDatum(65535'i32), INT4OID, false) == 65535'u16
    check datumToNim[uint32](ObjectIdGetDatum(0x80000005'u32), OIDOID, false) == 0x80000005'u32
    check datumToNim[uint64](ObjectIdGetDatum(0xFFFFFFFF'u32), OIDOID, false) == 0xFFFFFFFF'u64

    expect ValueError:
      discard datumToNim[int16](Int32GetDatum(40000'i32), INT4OID, false)
    expect ValueError:
      discard datumToNim[int8](Int32GetDatum(-200'i32), INT4OID, false)
    expect ValueError:
      discard datumToNim[uint32](Int32GetDatum(-1'i32), INT4OID, false)
    expect ValueError:
      discard datumToNim[uint8](Int32GetDatum(256'i32), INT4OID, false)

  test "Float, bool, char, string direct varlena, OidOutputFunctionCall fallback & detoasted copy cleanup":
    check datumToNim[float32](Float4GetDatum(1.25'f32), FLOAT4OID, false) == 1.25'f32
    check datumToNim[float64](Float8GetDatum(3.5'f64), FLOAT8OID, false) == 3.5'f64
    check datumToNim[float64](Int32GetDatum(77'i32), INT4OID, false) == 77.0'f64
    check classify(datumToNim[float64](Float8GetDatum(NaN), FLOAT8OID, false)) == fcNan
    check datumToNim[float64](Float8GetDatum(Inf), FLOAT8OID, false) == Inf

    check datumToNim[bool](BoolGetDatum(true), BOOLOID, false) == true
    check datumToNim[bool](BoolGetDatum(false), BOOLOID, false) == false
    check datumToNim[char](CharGetDatum(cchar('Z')), CHAROID, false) == 'Z'

    # Detoasted copy cleanup test for string & PgText
    mockResetStats()
    let toastD = makeTextDatum("detoast-me", triggerDetoastCopy = true)
    let gotStr = datumToNim[string](toastD, TEXTOID, false)
    check gotStr == "detoast-me"
    check mockGetDetoastCopyFreed() == 1

    mockResetStats()
    let toastTextD = makeTextDatum("pgtext-toast", triggerDetoastCopy = true)
    let pgTxt = datumToNim[PgText](toastTextD, VARCHAROID, false)
    check $pgTxt == "pgtext-toast"
    check mockGetDetoastCopyFreed() == 1

    # Fallback via OidOutputFunctionCall frees returned cstring
    mockResetStats()
    let outStr = datumToNim[string](Int64GetDatum(4242'i64), Oid(99991), false)
    check outStr == "oid_out:4242"
    check mockGetOutfuncFreed() == 1

  test "PgBytea with NUL bytes, JSONOID, enum, distinct":
    let bytesPayload = @[byte 0x00, 0x41, 0x00, 0xFF]
    let bd = makeByteaDatum(bytesPayload)
    let gotB = datumToNim[PgBytea](bd, BYTEAOID, false)
    check gotB.toBytes == bytesPayload

    let jd = makeTextDatum("""{"a":1,"b":"ok"}""")
    let jn = datumToNim[JsonNode](jd, JSONOID, false)
    check jn["a"].getInt == 1
    check jn["b"].getStr == "ok"
    check datumToNim[JsonNode](NullDatum, JSONOID, true).kind == JNull

    let ed = makeTextDatum("admin")
    check datumToNim[TestRole](ed, TEXTOID, false) == trAdmin

    check int64(datumToNim[AccountId](Int64GetDatum(9001'i64), INT8OID, false)) == 9001'i64
    check string(datumToNim[EmailAddr](makeTextDatum("u@x.io"), TEXTOID, false)) == "u@x.io"

  test "Binary array deconstruct_array with NULL elements":
    let ints = @[10'i32, -20'i32, 30'i32]
    let arrPtr = mockCreateInt4Array(unsafeAddr ints[0], cint(ints.len))
    let arrDatum = Datum(cast[uint64](cast[uint](arrPtr)))
    let gotInts = datumToNim[seq[int32]](arrDatum, INT4ARRAYOID, false)
    check gotInts == @[10'i32, -20'i32, 30'i32]

    var cstrs = @[cstring("one"), cstring(nil), cstring("")]
    var isNulls = @[false, true, false]
    let txtArrPtr = mockCreateOptTextArray(unsafeAddr cstrs[0], unsafeAddr isNulls[0], 3)
    let txtArrDatum = Datum(cast[uint64](cast[uint](txtArrPtr)))
    let gotOptSeq = datumToNim[seq[Option[string]]](txtArrDatum, TEXTARRAYOID, false)
    check gotOptSeq == @[some("one"), none(string), some("")]

  test "External pgxFromDatum extensibility hook":
    let td = makeTextDatum("custom-val")
    let pt = datumToNim[PluginTag](td, TEXTOID, false)
    check pt.label == "plugin:custom-val"

    let optSome = datumToNim[Option[PluginTag]](td, TEXTOID, false)
    check optSome.isSome
    check optSome.get.label == "plugin:custom-val"

    let optNone = datumToNim[Option[PluginTag]](NullDatum, TEXTOID, true)
    check optNone.isNone

  test "SpiPlan free double-free safety and invalid batchSize rejection":
    var plan = SpiPlan(raw: cast[SPIPlanPtr](0x1234'u), nargs: 0, kept: true)
    plan.free()
    plan.free() # Idempotent
    check mockGetFreeplanCalls() == 1
    expect ValueError:
      discard executePlan(plan)

    let u = table("users", "u")
    let q = Select(u.id).From(u)
    expect ValueError:
      for _ in fetchBatches[MockBatchRow](q, batchSize = 0):
        discard
    expect ValueError:
      for _ in stream[MockBatchRow](q, batchSize = -5):
        discard
