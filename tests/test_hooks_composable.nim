import std/[strutils, unittest]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql") &
         " -include postgres.h".}

{.emit: """
#include "postgres.h"
#include "executor/executor.h"
#include "tcop/utility.h"
#include "parser/analyze.h"
#include "utils/elog.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "nodes/value.h"
#include "pgx_hooks.h"
#include <setjmp.h>
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
    va_list args;
    va_start(args, fmt);
    int r = vsprintf(str, fmt, args);
    va_end(args);
    return r;
}

int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int r = vsnprintf(str, count, fmt, args);
    va_end(args);
    return r;
}

int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
    return vsnprintf(str, count, fmt, args);
}

char *pg_strerror(int errnum) {
    return strerror(errnum);
}

/* Allocator & PG_TRY/ereport mocks with real siglongjmp support */
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

int mockLastElevel = 0;
int mockLastSqlCode = 0;
int mockErrorEreportCount = 0;
char mockLastMsg[512] = {0};
char mockLastDetail[512] = {0};
char mockLastHint[512] = {0};

bool errstart(int elevel, const char *domain) {
    (void)domain;
    mockLastElevel = elevel;
    mockLastSqlCode = 0;
    mockLastMsg[0] = '\0';
    mockLastDetail[0] = '\0';
    mockLastHint[0] = '\0';
    if (elevel >= ERROR) {
        mockErrorEreportCount++;
    }
    return true;
}

bool errstart_cold(int elevel, const char *domain) {
    return errstart(elevel, domain);
}

int errcode(int sqlerrcode) {
    mockLastSqlCode = sqlerrcode;
    return 0;
}

int errmsg(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockLastMsg, sizeof(mockLastMsg), fmt, args);
    va_end(args);
    return 0;
}

int errdetail(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockLastDetail, sizeof(mockLastDetail), fmt, args);
    va_end(args);
    return 0;
}

int errhint(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(mockLastHint, sizeof(mockLastHint), fmt, args);
    va_end(args);
    return 0;
}

void errfinish(const char *filename, int lineno, const char *funcname) {
    (void)filename; (void)lineno; (void)funcname;
    if (mockLastElevel >= ERROR && PG_exception_stack != NULL) {
        siglongjmp(*PG_exception_stack, 1);
    }
}

void pg_re_throw(void) {
    if (PG_exception_stack != NULL) {
        siglongjmp(*PG_exception_stack, 1);
    }
    abort();
}

ErrorData *CopyErrorData(void) { return NULL; }
void FlushErrorState(void) {}
void FreeErrorData(ErrorData *edata) { (void)edata; }
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void *palloc(Size size) { return malloc(size ? size : 1); }
void pfree(void *ptr) { if (ptr) free(ptr); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size ? size : 1); }

/* PostgreSQL Global Hook Pointers & Standard Implementations */
ExecutorStart_hook_type ExecutorStart_hook = NULL;
ExecutorRun_hook_type ExecutorRun_hook = NULL;
ExecutorFinish_hook_type ExecutorFinish_hook = NULL;
ExecutorEnd_hook_type ExecutorEnd_hook = NULL;
ProcessUtility_hook_type ProcessUtility_hook = NULL;
emit_log_hook_type emit_log_hook = NULL;
post_parse_analyze_hook_type post_parse_analyze_hook = NULL;

int mockStdExecStartCalls = 0;
int mockStdExecRunCalls = 0;
int mockStdExecFinishCalls = 0;
int mockStdExecEndCalls = 0;
int mockStdUtilCalls = 0;

int mockPrevExecStartCalls = 0;
int mockPrevExecRunCalls = 0;
int mockPrevExecFinishCalls = 0;
int mockPrevExecEndCalls = 0;
int mockPrevUtilCalls = 0;
int mockPrevEmitLogCalls = 0;
int mockPrevPostParseCalls = 0;
bool mockPrevShouldError = false;

typedef void (*MockOrderTrackerFn)(char *tag);
static MockOrderTrackerFn mockOrderTracker = NULL;
void pgx_test_set_order_tracker(MockOrderTrackerFn fn) { mockOrderTracker = fn; }

static void track_tag(const char *tag) {
    if (mockOrderTracker != NULL) mockOrderTracker((char *)tag);
}

void standard_ExecutorStart(QueryDesc *qd, int eflags) {
    (void)qd; (void)eflags;
    mockStdExecStartCalls++;
    track_tag("std_start");
    if (mockPrevShouldError && PG_exception_stack != NULL) {
        errstart(ERROR, NULL);
        errcode(ERRCODE_INTERNAL_ERROR);
        errmsg("%s", "standard_ExecutorStart failed");
        errfinish(__FILE__, __LINE__, __func__);
    }
}

#if PG_VERSION_NUM >= 180000
void standard_ExecutorRun(QueryDesc *qd, ScanDirection dir, uint64 count) {
    (void)qd; (void)dir; (void)count;
    mockStdExecRunCalls++;
    track_tag("std_run");
}
#else
void standard_ExecutorRun(QueryDesc *qd, ScanDirection dir, uint64 count, bool execute_once) {
    (void)qd; (void)dir; (void)count; (void)execute_once;
    mockStdExecRunCalls++;
    track_tag("std_run");
}
#endif

void standard_ExecutorFinish(QueryDesc *qd) {
    (void)qd;
    mockStdExecFinishCalls++;
    track_tag("std_finish");
}

void standard_ExecutorEnd(QueryDesc *qd) {
    (void)qd;
    mockStdExecEndCalls++;
    track_tag("std_end");
}

void standard_ProcessUtility(PlannedStmt *pstmt, const char *queryString, bool readOnlyTree,
                             ProcessUtilityContext context, ParamListInfo params,
                             QueryEnvironment *queryEnv, DestReceiver *dest, QueryCompletion *qc) {
    (void)pstmt; (void)queryString; (void)readOnlyTree; (void)context;
    (void)params; (void)queryEnv; (void)dest; (void)qc;
    mockStdUtilCalls++;
    track_tag("std_util");
    if (mockPrevShouldError && PG_exception_stack != NULL) {
        errstart(ERROR, NULL);
        errcode(ERRCODE_INTERNAL_ERROR);
        errmsg("%s", "standard_ProcessUtility failed");
        errfinish(__FILE__, __LINE__, __func__);
    }
}

static void mock_prev_exec_start(QueryDesc *qd, int eflags) {
    (void)qd; (void)eflags;
    mockPrevExecStartCalls++;
    track_tag("prev_start");
    if (mockPrevShouldError && PG_exception_stack != NULL) {
        errstart(ERROR, NULL);
        errcode(ERRCODE_INTERNAL_ERROR);
        errmsg("%s", "prev_exec_start siglongjmp");
        errfinish(__FILE__, __LINE__, __func__);
    }
}

#if PG_VERSION_NUM >= 180000
static void mock_prev_exec_run(QueryDesc *qd, ScanDirection dir, uint64 count) {
    (void)qd; (void)dir; (void)count;
    mockPrevExecRunCalls++;
    track_tag("prev_run");
}
#else
static void mock_prev_exec_run(QueryDesc *qd, ScanDirection dir, uint64 count, bool execute_once) {
    (void)qd; (void)dir; (void)count; (void)execute_once;
    mockPrevExecRunCalls++;
    track_tag("prev_run");
}
#endif

static void mock_prev_exec_finish(QueryDesc *qd) {
    (void)qd;
    mockPrevExecFinishCalls++;
    track_tag("prev_finish");
}

static void mock_prev_exec_end(QueryDesc *qd) {
    (void)qd;
    mockPrevExecEndCalls++;
    track_tag("prev_end");
}

static void mock_prev_process_utility(PlannedStmt *pstmt, const char *queryString, bool readOnlyTree,
                                      ProcessUtilityContext context, ParamListInfo params,
                                      QueryEnvironment *queryEnv, DestReceiver *dest, QueryCompletion *qc) {
    (void)pstmt; (void)queryString; (void)readOnlyTree; (void)context;
    (void)params; (void)queryEnv; (void)dest; (void)qc;
    mockPrevUtilCalls++;
    track_tag("prev_util");
}

static void mock_prev_emit_log(ErrorData *edata) {
    (void)edata;
    mockPrevEmitLogCalls++;
    track_tag("prev_emit_log");
}

static void mock_prev_post_parse(ParseState *pstate, Query *query, JumbleState *jstate) {
    (void)pstate; (void)query; (void)jstate;
    mockPrevPostParseCalls++;
    track_tag("prev_post_parse");
}

void pgx_test_reset_hook_mocks(void) {
    ExecutorStart_hook = NULL;
    ExecutorRun_hook = NULL;
    ExecutorFinish_hook = NULL;
    ExecutorEnd_hook = NULL;
    ProcessUtility_hook = NULL;
    emit_log_hook = NULL;
    post_parse_analyze_hook = NULL;

    mockStdExecStartCalls = 0;
    mockStdExecRunCalls = 0;
    mockStdExecFinishCalls = 0;
    mockStdExecEndCalls = 0;
    mockStdUtilCalls = 0;

    mockPrevExecStartCalls = 0;
    mockPrevExecRunCalls = 0;
    mockPrevExecFinishCalls = 0;
    mockPrevExecEndCalls = 0;
    mockPrevUtilCalls = 0;
    mockPrevEmitLogCalls = 0;
    mockPrevPostParseCalls = 0;
    mockPrevShouldError = false;

    mockLastElevel = 0;
    mockLastSqlCode = 0;
    mockErrorEreportCount = 0;
    mockLastMsg[0] = '\0';
    mockLastDetail[0] = '\0';
    mockLastHint[0] = '\0';
    mockOrderTracker = NULL;
}

void pgx_test_install_prev_hooks(void) {
    ExecutorStart_hook = mock_prev_exec_start;
    ExecutorRun_hook = mock_prev_exec_run;
    ExecutorFinish_hook = mock_prev_exec_finish;
    ExecutorEnd_hook = mock_prev_exec_end;
    ProcessUtility_hook = mock_prev_process_utility;
    emit_log_hook = mock_prev_emit_log;
    post_parse_analyze_hook = mock_prev_post_parse;
}

void pgx_test_invoke_executor_start(QueryDesc *qd, int eflags) {
    if (ExecutorStart_hook) ExecutorStart_hook(qd, eflags);
    else standard_ExecutorStart(qd, eflags);
}

void pgx_test_invoke_executor_run(QueryDesc *qd, ScanDirection dir, uint64 count) {
#if PG_VERSION_NUM >= 180000
    if (ExecutorRun_hook) ExecutorRun_hook(qd, dir, count);
    else standard_ExecutorRun(qd, dir, count);
#else
    if (ExecutorRun_hook) ExecutorRun_hook(qd, dir, count, true);
    else standard_ExecutorRun(qd, dir, count, true);
#endif
}

void pgx_test_invoke_executor_finish(QueryDesc *qd) {
    if (ExecutorFinish_hook) ExecutorFinish_hook(qd);
    else standard_ExecutorFinish(qd);
}

void pgx_test_invoke_executor_end(QueryDesc *qd) {
    if (ExecutorEnd_hook) ExecutorEnd_hook(qd);
    else standard_ExecutorEnd(qd);
}

void pgx_test_invoke_process_utility(PlannedStmt *pstmt, const char *sql, ProcessUtilityContext ctx) {
    if (ProcessUtility_hook) ProcessUtility_hook(pstmt, sql, false, ctx, NULL, NULL, NULL, NULL);
    else standard_ProcessUtility(pstmt, sql, false, ctx, NULL, NULL, NULL, NULL);
}

bool pgx_test_invoke_process_utility_try(PlannedStmt *pstmt, const char *sql, ProcessUtilityContext ctx) {
    volatile bool ok = false;
    PG_TRY();
    {
        pgx_test_invoke_process_utility(pstmt, sql, ctx);
        ok = true;
    }
    PG_CATCH();
    {
        ok = false;
    }
    PG_END_TRY();
    return ok;
}

bool pgx_test_invoke_executor_start_try(QueryDesc *qd, int eflags) {
    volatile bool ok = false;
    PG_TRY();
    {
        pgx_test_invoke_executor_start(qd, eflags);
        ok = true;
    }
    PG_CATCH();
    {
        ok = false;
    }
    PG_END_TRY();
    return ok;
}

void pgx_test_invoke_emit_log(ErrorData *ed) {
    if (emit_log_hook) emit_log_hook(ed);
}

void pgx_test_invoke_post_parse(ParseState *ps, Query *q, JumbleState *js) {
    if (post_parse_analyze_hook) post_parse_analyze_hook(ps, q, js);
}

/* Synthetic AST / QueryDesc / PlannedStmt Builders */
static Node *make_pgx_str_node(const char *s) {
#if PG_VERSION_NUM >= 150000
    String *n = (String *)calloc(1, sizeof(String));
    n->type = T_String;
    n->sval = strdup(s);
    return (Node *)n;
#else
    Value *n = (Value *)calloc(1, sizeof(Value));
    n->type = T_String;
    n->val.str = strdup(s);
    return (Node *)n;
#endif
}

static List *make_pgx_list(int count, ...) {
    List *lst = (List *)calloc(1, sizeof(List) + sizeof(ListCell) * (size_t)count);
    va_list ap;
    lst->type = T_List;
    lst->length = count;
    lst->max_length = count;
    lst->elements = lst->initial_elements;
    va_start(ap, count);
    for (int i = 0; i < count; i++) {
        lst->elements[i].ptr_value = va_arg(ap, void *);
    }
    va_end(ap);
    return lst;
}

QueryDesc *pgx_test_make_qdesc(const char *sql, int normOp, uint64 rows, bool withEstate) {
    QueryDesc *qd = (QueryDesc *)calloc(1, sizeof(QueryDesc));
    PlannedStmt *ps = (PlannedStmt *)calloc(1, sizeof(PlannedStmt));
    ps->type = T_PlannedStmt;
    ps->queryId = 98765;
    qd->plannedstmt = ps;
    qd->sourceText = sql ? strdup(sql) : NULL;
    switch (normOp) {
        case PGX_CMD_SELECT:  qd->operation = CMD_SELECT; break;
        case PGX_CMD_UPDATE:  qd->operation = CMD_UPDATE; break;
        case PGX_CMD_INSERT:  qd->operation = CMD_INSERT; break;
        case PGX_CMD_DELETE:  qd->operation = CMD_DELETE; break;
#if PG_VERSION_NUM >= 150000
        case PGX_CMD_MERGE:   qd->operation = CMD_MERGE; break;
#endif
        case PGX_CMD_UTILITY: qd->operation = CMD_UTILITY; break;
        case PGX_CMD_NOTHING: qd->operation = CMD_NOTHING; break;
        default:              qd->operation = CMD_UNKNOWN; break;
    }
    if (withEstate) {
        EState *es = (EState *)calloc(1, sizeof(EState));
        es->type = T_EState;
        es->es_processed = rows;
        qd->estate = es;
    }
    return qd;
}

PlannedStmt *pgx_test_make_utility_pstmt(int stmtKind) {
    PlannedStmt *ps = (PlannedStmt *)calloc(1, sizeof(PlannedStmt));
    ps->type = T_PlannedStmt;
    ps->commandType = CMD_UTILITY;
    if (stmtKind == 1) {
        CreateStmt *cs = (CreateStmt *)calloc(1, sizeof(CreateStmt));
        cs->type = T_CreateStmt;
        ps->utilityStmt = (Node *)cs;
    } else if (stmtKind == 2) {
        AlterTableStmt *ats = (AlterTableStmt *)calloc(1, sizeof(AlterTableStmt));
        ats->type = T_AlterTableStmt;
        ps->utilityStmt = (Node *)ats;
    } else if (stmtKind == 3) {
        DropStmt *ds = (DropStmt *)calloc(1, sizeof(DropStmt));
        ds->type = T_DropStmt;
        ds->removeType = OBJECT_TABLE;
        ps->utilityStmt = (Node *)ds;
    }
    return ps;
}

PlannedStmt *pgx_test_make_drop_table_single(const char *schema, const char *tbl) {
    PlannedStmt *ps = pgx_test_make_utility_pstmt(3);
    DropStmt *ds = (DropStmt *)ps->utilityStmt;
    List *nameList = (schema && schema[0])
        ? make_pgx_list(2, make_pgx_str_node(schema), make_pgx_str_node(tbl))
        : make_pgx_list(1, make_pgx_str_node(tbl));
    ds->objects = make_pgx_list(1, nameList);
    return ps;
}

PlannedStmt *pgx_test_make_drop_table_multi(const char *s1, const char *t1, const char *t2) {
    PlannedStmt *ps = pgx_test_make_utility_pstmt(3);
    DropStmt *ds = (DropStmt *)ps->utilityStmt;
    List *n1 = (s1 && s1[0])
        ? make_pgx_list(2, make_pgx_str_node(s1), make_pgx_str_node(t1))
        : make_pgx_list(1, make_pgx_str_node(t1));
    List *n2 = make_pgx_list(1, make_pgx_str_node(t2));
    ds->objects = make_pgx_list(2, n1, n2);
    return ps;
}

PlannedStmt *pgx_test_make_drop_schema(const char *schemaName) {
    PlannedStmt *ps = pgx_test_make_utility_pstmt(3);
    DropStmt *ds = (DropStmt *)ps->utilityStmt;
    ds->removeType = OBJECT_SCHEMA;
    ds->objects = make_pgx_list(1, make_pgx_str_node(schemaName));
    return ps;
}

PlannedStmt *pgx_test_make_drop_type(const char *schema, const char *typeName) {
    PlannedStmt *ps = pgx_test_make_utility_pstmt(3);
    DropStmt *ds = (DropStmt *)ps->utilityStmt;
    TypeName *tn = (TypeName *)calloc(1, sizeof(TypeName));
    tn->type = T_TypeName;
    tn->names = (schema && schema[0])
        ? make_pgx_list(2, make_pgx_str_node(schema), make_pgx_str_node(typeName))
        : make_pgx_list(1, make_pgx_str_node(typeName));
    ds->removeType = OBJECT_TYPE;
    ds->objects = make_pgx_list(1, tn);
    return ps;
}

PlannedStmt *pgx_test_make_drop_function(const char *schema, const char *fnName) {
    PlannedStmt *ps = pgx_test_make_utility_pstmt(3);
    DropStmt *ds = (DropStmt *)ps->utilityStmt;
    ObjectWithArgs *owa = (ObjectWithArgs *)calloc(1, sizeof(ObjectWithArgs));
    owa->type = T_ObjectWithArgs;
    owa->objname = (schema && schema[0])
        ? make_pgx_list(2, make_pgx_str_node(schema), make_pgx_str_node(fnName))
        : make_pgx_list(1, make_pgx_str_node(fnName));
    ds->removeType = OBJECT_FUNCTION;
    ds->objects = make_pgx_list(1, owa);
    return ps;
}
""".}

import ../src/pgxcrown

type
  MockOrderTrackerFn = proc(tag: cstring) {.cdecl.}

proc pgx_test_reset_hook_mocks() {.importc, nodecl.}
proc pgx_test_install_prev_hooks() {.importc, nodecl.}
proc pgx_test_set_order_tracker(fn: MockOrderTrackerFn) {.importc, nodecl.}
proc pgx_test_invoke_executor_start(qd: QueryDescPtr, eflags: cint) {.importc, nodecl.}
proc pgx_test_invoke_executor_run(qd: QueryDescPtr, dir: ScanDirection, count: uint64) {.importc, nodecl.}
proc pgx_test_invoke_executor_finish(qd: QueryDescPtr) {.importc, nodecl.}
proc pgx_test_invoke_executor_end(qd: QueryDescPtr) {.importc, nodecl.}
proc pgx_test_invoke_process_utility(pstmt: PlannedStmtPtr, sql: cstring, ctx: ProcessUtilityContext) {.importc, nodecl.}
proc pgx_test_invoke_process_utility_try(pstmt: PlannedStmtPtr, sql: cstring, ctx: ProcessUtilityContext): bool {.importc, nodecl.}
proc pgx_test_invoke_executor_start_try(qd: QueryDescPtr, eflags: cint): bool {.importc, nodecl.}
proc pgx_test_invoke_emit_log(ed: ptr ErrorData) {.importc, nodecl.}
proc pgx_test_invoke_post_parse(ps: ptr ParseState, q: ptr Query, js: JumbleStatePtr) {.importc, nodecl.}

proc pgx_test_make_qdesc(sql: cstring, normOp: int32, rows: uint64, withEstate: bool): QueryDescPtr {.importc, nodecl.}
proc pgx_test_make_utility_pstmt(stmtKind: cint): PlannedStmtPtr {.importc, nodecl.}
proc pgx_test_make_drop_table_single(schema, tbl: cstring): PlannedStmtPtr {.importc, nodecl.}
proc pgx_test_make_drop_table_multi(s1, t1, t2: cstring): PlannedStmtPtr {.importc, nodecl.}
proc pgx_test_make_drop_schema(schemaName: cstring): PlannedStmtPtr {.importc, nodecl.}
proc pgx_test_make_drop_type(schema, typeName: cstring): PlannedStmtPtr {.importc, nodecl.}
proc pgx_test_make_drop_function(schema, fnName: cstring): PlannedStmtPtr {.importc, nodecl.}

var
  mockStdExecStartCalls {.importc, nodecl.}: cint
  mockStdExecRunCalls {.importc, nodecl.}: cint
  mockStdExecFinishCalls {.importc, nodecl.}: cint
  mockStdExecEndCalls {.importc, nodecl.}: cint
  mockStdUtilCalls {.importc, nodecl.}: cint

  mockPrevExecStartCalls {.importc, nodecl.}: cint
  mockPrevExecRunCalls {.importc, nodecl.}: cint
  mockPrevExecFinishCalls {.importc, nodecl.}: cint
  mockPrevExecEndCalls {.importc, nodecl.}: cint
  mockPrevUtilCalls {.importc, nodecl.}: cint
  mockPrevEmitLogCalls {.importc, nodecl.}: cint
  mockPrevPostParseCalls {.importc, nodecl.}: cint
  mockPrevShouldError {.importc, nodecl.}: bool

  mockLastSqlCode {.importc, nodecl.}: cint
  mockErrorEreportCount {.importc, nodecl.}: cint
  mockLastMsg {.importc, nodecl.}: cstring
  mockLastDetail {.importc, nodecl.}: cstring
  mockLastHint {.importc, nodecl.}: cstring

var gTrace: seq[string] = @[]

proc recordTag(tag: cstring) {.cdecl.} =
  gTrace.add($tag)

suite "Pgxcrown - Composable Hooks, Cross-Version Accessors & Siglongjmp Safety":

  setup:
    resetComposableHooks()
    pgx_test_reset_hook_mocks()
    gTrace = @[]
    pgx_test_set_order_tracker(recordTag)

  teardown:
    resetComposableHooks()
    pgx_test_reset_hook_mocks()
    gTrace = @[]

  test "Multi-hook composition, chaining order (pre -> prev -> post), and idempotent install":
    pgx_test_install_prev_hooks()

    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("nim_start_pre_1:" & $eflags & ":" & info.sourceText)
    , hpPre)
    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("nim_start_pre_2")
    , hpPre)
    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("nim_start_post_1")
    , hpPost)

    check isExecutorStartHookInstalled()
    check executorStartHookCount() == 3

    let qd = pgx_test_make_qdesc("SELECT 42", ord(pgxCmdSelect).int32, 7'u64, true)
    pgx_test_invoke_executor_start(qd, 16)

    check mockPrevExecStartCalls == 1
    check mockStdExecStartCalls == 0
    check gTrace == @[
      "nim_start_pre_1:16:SELECT 42",
      "nim_start_pre_2",
      "prev_start",
      "nim_start_post_1"
    ]

    # ExecutorRun (PG 18 3-arg vs PG 14-17 4-arg ABI guard)
    gTrace = @[]
    registerExecutorRunHook(proc(info: ExecutorQueryInfo, dir: ScanDirection, count: uint64, execOnce: bool) =
      gTrace.add("nim_run_pre:" & $ord(dir) & ":" & $count & ":" & $execOnce)
    , hpPre)
    registerExecutorRunHook(proc(info: ExecutorQueryInfo, dir: ScanDirection, count: uint64, execOnce: bool) =
      gTrace.add("nim_run_post:" & $info.rowsProcessed)
    , hpPost)
    check isExecutorRunHookInstalled()
    pgx_test_invoke_executor_run(qd, ForwardScanDirection, 100'u64)
    check mockPrevExecRunCalls == 1
    check gTrace == @[
      "nim_run_pre:1:100:true",
      "prev_run",
      "nim_run_post:7"
    ]

    # ExecutorFinish & ExecutorEnd
    gTrace = @[]
    registerExecutorFinishHook(proc(info: ExecutorQueryInfo) =
      gTrace.add("nim_finish_pre")
    , hpPre)
    registerExecutorEndHook(proc(info: ExecutorQueryInfo) =
      gTrace.add("nim_end_pre:" & $info.rowsProcessed)
    , hpPre)
    pgx_test_invoke_executor_finish(qd)
    pgx_test_invoke_executor_end(qd)
    check mockPrevExecFinishCalls == 1
    check mockPrevExecEndCalls == 1
    check gTrace == @[
      "nim_finish_pre",
      "prev_finish",
      "nim_end_pre:7",
      "prev_end"
    ]

    # ProcessUtility & post_parse_analyze
    gTrace = @[]
    let ps = pgx_test_make_utility_pstmt(1)
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      gTrace.add("nim_util_pre:" & info.tagName & ":" & info.queryString)
    , hpPre)
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      gTrace.add("nim_util_post")
    , hpPost)
    pgx_test_invoke_process_utility(ps, "CREATE TABLE t(x int)", PROCESS_UTILITY_TOPLEVEL)
    check mockPrevUtilCalls == 1
    check gTrace == @[
      "nim_util_pre:CreateStmt:CREATE TABLE t(x int)",
      "prev_util",
      "nim_util_post"
    ]

    gTrace = @[]
    registerPostParseHook(proc(pstate: ptr ParseState, q: ptr Query, js: JumbleStatePtr) =
      gTrace.add("nim_pp_pre")
    , hpPre)
    registerPostParseHook(proc(pstate: ptr ParseState, q: ptr Query, js: JumbleStatePtr) =
      gTrace.add("nim_pp_post")
    , hpPost)
    pgx_test_invoke_post_parse(nil, nil, nil)
    check mockPrevPostParseCalls == 1
    check gTrace == @["nim_pp_pre", "prev_post_parse", "nim_pp_post"]

  test "Standard fallbacks execute when no prior hook was installed":
    let qd = pgx_test_make_qdesc("INSERT INTO t VALUES (1)", ord(pgxCmdInsert).int32, 3'u64, true)
    let ps = pgx_test_make_utility_pstmt(2)

    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("start")
    )
    registerExecutorRunHook(proc(info: ExecutorQueryInfo, dir: ScanDirection, count: uint64, execOnce: bool) =
      gTrace.add("run")
    )
    registerExecutorFinishHook(proc(info: ExecutorQueryInfo) =
      gTrace.add("finish")
    )
    registerExecutorEndHook(proc(info: ExecutorQueryInfo) =
      gTrace.add("end")
    )
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      gTrace.add("util")
    )

    pgx_test_invoke_executor_start(qd, 0)
    pgx_test_invoke_executor_run(qd, ForwardScanDirection, 0'u64)
    pgx_test_invoke_executor_finish(qd)
    pgx_test_invoke_executor_end(qd)
    pgx_test_invoke_process_utility(ps, "ALTER TABLE t ADD COLUMN y int", PROCESS_UTILITY_TOPLEVEL)

    check mockStdExecStartCalls == 1
    check mockStdExecRunCalls == 1
    check mockStdExecFinishCalls == 1
    check mockStdExecEndCalls == 1
    check mockStdUtilCalls == 1
    check gTrace == @[
      "start", "std_start",
      "run", "std_run",
      "finish", "std_finish",
      "end", "std_end",
      "util", "std_util"
    ]

  test "QueryDesc normalized CmdType, NULL guards, and rowsProcessed across PG 14-18":
    let nilQd: QueryDescPtr = nil
    check nilQd.sourceText == ""
    check nilQd.operation == pgxCmdUnknown
    check nilQd.operationName == "UNKNOWN"
    check nilQd.rowsProcessed == 0'u64
    check nilQd.queryId == 0
    check not nilQd.hasEstate

    let noEstateQd = pgx_test_make_qdesc("SELECT 1", ord(pgxCmdSelect).int32, 99'u64, false)
    check noEstateQd.sourceText == "SELECT 1"
    check noEstateQd.operation == pgxCmdSelect
    check noEstateQd.operationName == "SELECT"
    check noEstateQd.rowsProcessed == 0'u64
    check noEstateQd.queryId == 98765
    check not noEstateQd.hasEstate

    for cmd in [pgxCmdSelect, pgxCmdUpdate, pgxCmdInsert, pgxCmdDelete, pgxCmdUtility, pgxCmdNothing]:
      let q = pgx_test_make_qdesc("stmt", ord(cmd).int32, 12'u64, true)
      check q.operation == cmd
      check q.operationName == $cmd
      check q.rowsProcessed == 12'u64
      check q.hasEstate

  test "PlannedStmt & DropStmt C inline accessors format targets safely across PG 14-18":
    let nilPs: PlannedStmtPtr = nil
    check nilPs.nodeTag == 0
    check nilPs.tagName == "None"
    check not nilPs.isDropStmt
    check not nilPs.isDropTable
    check nilPs.dropRemoveType == -1
    check nilPs.dropTargetsCsv == ""
    check nilPs.dropTargets.len == 0

    let createPs = pgx_test_make_utility_pstmt(1)
    check createPs.tagName == "CreateStmt"
    check not createPs.isDropStmt
    check createPs.dropTargetsCsv == ""

    let dropSingle = pgx_test_make_drop_table_single(nil, "protected_audit_tbl")
    check dropSingle.tagName == "DropStmt"
    check dropSingle.isDropStmt
    check dropSingle.isDropTable
    check dropSingle.dropTargetsCsv == "protected_audit_tbl"
    check dropSingle.dropTargets == @["protected_audit_tbl"]
    check dropSingle.dropTargetsContain("protected_audit_tbl")
    check dropSingle.dropTargetsContain("PROTECTED_AUDIT_TBL")
    check not dropSingle.dropTargetsContain("other_tbl")

    let dropMulti = pgx_test_make_drop_table_multi("public", "protected_audit_tbl", "temp_scratch")
    check dropMulti.isDropStmt
    check dropMulti.isDropTable
    check dropMulti.dropTargetsCsv == "public.protected_audit_tbl,temp_scratch"
    check dropMulti.dropTargets == @["public.protected_audit_tbl", "temp_scratch"]
    check dropMulti.dropTargetsContain("protected_audit_tbl")
    check dropMulti.dropTargetsContain("public.protected_audit_tbl")
    check dropMulti.dropTargetsContain("temp_scratch")

    let dropSchema = pgx_test_make_drop_schema("analytics")
    check dropSchema.isDropStmt
    check not dropSchema.isDropTable
    check dropSchema.dropTargetsCsv == "analytics"

    let dropType = pgx_test_make_drop_type("myschema", "custom_money")
    check dropType.isDropStmt
    check dropType.dropTargetsCsv == "myschema.custom_money"

    let dropFn = pgx_test_make_drop_function("myschema", "calc_total")
    check dropFn.isDropStmt
    check dropFn.dropTargetsCsv == "myschema.calc_total"

  test "Exception-to-SQLSTATE translation and siglongjmp safety in ProcessUtility & ExecutorStart":
    let dropProtected = pgx_test_make_drop_table_single(nil, "protected_audit_tbl")

    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      if info.isDropTable and info.dropTargetsContain("protected_audit_tbl"):
        let localStr = "blocking protected table: " & info.dropTargetsCsv
        raisePgError("42501", localStr, detail = "protected audit policy", hint = "remove protection first")
    )

    let ok = pgx_test_invoke_process_utility_try(dropProtected, "DROP TABLE protected_audit_tbl", PROCESS_UTILITY_TOPLEVEL)
    check not ok
    check mockStdUtilCalls == 0
    check mockErrorEreportCount == 1
    check unpackSqlState(mockLastSqlCode) == "42501"
    check $mockLastMsg == "blocking protected table: protected_audit_tbl"
    check $mockLastDetail == "protected audit policy"
    check $mockLastHint == "remove protection first"

    # Also test ValueError -> 22023 and Defect -> 22012
    resetComposableHooks()
    pgx_test_reset_hook_mocks()
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      raise newException(ValueError, "bad utility param")
    )
    check not pgx_test_invoke_process_utility_try(dropProtected, "DROP TABLE x", PROCESS_UTILITY_TOPLEVEL)
    check unpackSqlState(mockLastSqlCode) == "22023"

    resetComposableHooks()
    pgx_test_reset_hook_mocks()
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      raise newException(DivByZeroDefect, "div zero in hook")
    )
    check not pgx_test_invoke_process_utility_try(dropProtected, "DROP TABLE x", PROCESS_UTILITY_TOPLEVEL)
    check unpackSqlState(mockLastSqlCode) == "22012"

    # siglongjmp thrown by prev_* inside C trampoline unwinds cleanly and skips post-hook
    resetComposableHooks()
    pgx_test_reset_hook_mocks()
    gTrace = @[]
    pgx_test_set_order_tracker(recordTag)
    pgx_test_install_prev_hooks()
    mockPrevShouldError = true

    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("nim_pre_before_jump")
    , hpPre)
    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      gTrace.add("nim_post_must_not_run")
    , hpPost)

    let qd = pgx_test_make_qdesc("SELECT 1", ord(pgxCmdSelect).int32, 0'u64, false)
    check not pgx_test_invoke_executor_start_try(qd, 0)
    check gTrace == @["nim_pre_before_jump", "prev_start"]

  test "emit_log_hook guards infinite recursion and never triggers ereport(ERROR)":
    pgx_test_install_prev_hooks()
    var outerHits = 0
    var ed: ErrorData
    ed.elevel = LOG
    ed.message = "outer log event".cstring
    ed.output_to_server = true

    registerEmitLogHook(proc(edata: ptr ErrorData) =
      inc outerHits
      # Attempt recursive re-entry through emit_log_hook
      var innerEd: ErrorData
      innerEd.elevel = LOG
      innerEd.message = "inner recursive log".cstring
      pgx_test_invoke_emit_log(addr innerEd)
      # Also verify raising inside emit_log does not call ereport(ERROR)
      raise newException(ValueError, "must be swallowed safely in emit_log")
    )

    pgx_test_invoke_emit_log(addr ed)
    check outerHits == 1
    check mockErrorEreportCount == 0
    check mockPrevEmitLogCalls == 2 # outer + inner forwarded to prev_emit_log without Nim recursion

  test "resetComposableHooks restores original hooks and allows clean re-registration":
    pgx_test_install_prev_hooks()
    var hits = 0
    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      inc hits
    )
    registerProcessUtilityHook(proc(info: UtilityStmtInfo) =
      inc hits
    )
    check isExecutorStartHookInstalled()
    check isProcessUtilityHookInstalled()
    check executorStartHookCount() == 1
    check processUtilityHookCount() == 1

    resetComposableHooks()
    check not isExecutorStartHookInstalled()
    check not isProcessUtilityHookInstalled()
    check executorStartHookCount() == 0
    check processUtilityHookCount() == 0

    let qd = pgx_test_make_qdesc("SELECT 1", ord(pgxCmdSelect).int32, 0'u64, false)
    let ps = pgx_test_make_utility_pstmt(1)
    pgx_test_invoke_executor_start(qd, 0)
    pgx_test_invoke_process_utility(ps, "CREATE TABLE x(a int)", PROCESS_UTILITY_TOPLEVEL)
    check hits == 0
    check mockPrevExecStartCalls == 1
    check mockPrevUtilCalls == 1

    # Re-registering works cleanly after reset
    registerExecutorStartHook(proc(info: ExecutorQueryInfo, eflags: cint) =
      inc hits
    )
    pgx_test_invoke_executor_start(qd, 0)
    check hits == 1
    check mockPrevExecStartCalls == 2

  test "Registration rejects nil callbacks":
    expect(ValueError):
      registerExecutorStartHook(nil)
    expect(ValueError):
      registerProcessUtilityHook(nil)
    expect(ValueError):
      registerEmitLogHook(nil)
    expect(ValueError):
      registerPostParseHook(nil)
