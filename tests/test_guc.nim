import std/strutils

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

import std/[unittest, options, math]
import ../src/pgxcrown

{.emit: """
#include "postgres.h"
#include "utils/guc.h"
#include "utils/elog.h"
#include "miscadmin.h"
#include "pgx_guc.h"
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

/* ============================================================================
 * PostgreSQL Error & Memory Context Mocks for Standalone Unit Testing
 * ============================================================================ */
MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;
sigjmp_buf *PG_exception_stack = NULL;
ErrorContextCallback *error_context_stack = NULL;

static ErrorData mockPendingEdata;
static int mockErrSqlState = 0;
static char mockErrMsgBuf[256] = {0};

static void mockTriggerPgError(int sqlerrcode, const char *msg) {
    memset(&mockPendingEdata, 0, sizeof(mockPendingEdata));
    mockPendingEdata.elevel = ERROR;
    mockPendingEdata.sqlerrcode = sqlerrcode;
    mockPendingEdata.message = strdup(msg ? msg : "mock error");
    if (PG_exception_stack != NULL) {
        siglongjmp(*PG_exception_stack, 1);
    }
    abort();
}

bool errstart(int elevel, const char *domain) { (void)elevel; (void)domain; return false; }
bool errstart_cold(int elevel, const char *domain) { (void)elevel; (void)domain; return false; }
void errfinish(const char *filename, int lineno, const char *funcname) { (void)filename; (void)lineno; (void)funcname; }
int errcode(int sqlerrcode) { mockErrSqlState = sqlerrcode; return 0; }
int errmsg(const char *fmt, ...) { (void)fmt; return 0; }
int errdetail(const char *fmt, ...) { (void)fmt; return 0; }
int errhint(const char *fmt, ...) { (void)fmt; return 0; }
ErrorData *CopyErrorData(void) {
    ErrorData *ed = (ErrorData *)calloc(1, sizeof(ErrorData));
    *ed = mockPendingEdata;
    if (mockPendingEdata.message) ed->message = strdup(mockPendingEdata.message);
    return ed;
}
void FlushErrorState(void) {
    if (mockPendingEdata.message) {
        free(mockPendingEdata.message);
        mockPendingEdata.message = NULL;
    }
}
void pg_re_throw(void) { abort(); }
void FreeErrorData(ErrorData *edata) {
    if (edata) {
        if (edata->message) free(edata->message);
        free(edata);
    }
}
char *pstrdup(const char *in) { return in ? strdup(in) : NULL; }
void *palloc(Size size) { return malloc(size); }
void pfree(void *ptr) { if (ptr) free(ptr); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size); }

/* ============================================================================
 * PostgreSQL GUC & Security Context Mocks
 * ============================================================================ */
bool process_shared_preload_libraries_in_progress = false;
static bool mockInSecRest = false;
static bool mockIsSuperuser = true;
static Oid mockUserId = (Oid)10;

bool InSecurityRestrictedOperation(void) { return mockInSecRest; }
bool superuser(void) { return mockIsSuperuser; }
Oid GetUserId(void) { return mockUserId; }

typedef enum {
    MOCK_GUC_BOOL = 0,
    MOCK_GUC_INT,
    MOCK_GUC_REAL,
    MOCK_GUC_STRING,
    MOCK_GUC_ENUM
} MockGucKind;

typedef struct {
    bool used;
    MockGucKind kind;
    const char *name;
    const char *short_desc;
    const char *long_desc;
    void *value_addr;
    const char *boot_str;
    bool str_addr_was_null_on_define;
    int min_int;
    int max_int;
    double min_real;
    double max_real;
    const struct config_enum_entry *enum_opts;
    GucContext context;
    int flags;
    char current_text[128];
} MockGucSlot;

#define MAX_MOCK_GUCS 32
static MockGucSlot mockGucs[MAX_MOCK_GUCS];
static int mockGucCount = 0;

static char mockReservedPrefix[128] = {0};
static int mockReserveCalls = 0;
static int mockSetCalls = 0;
static int mockGetCalls = 0;
static int mockLastSetCtx = -1;
static int mockLastSetAct = -1;
static Oid mockLastSetRole = InvalidOid;
static bool mockUsedExtApi = false;
static char mockLastSetName[128] = {0};
static char mockLastSetVal[128] = {0};

static void mockResetState(void) {
    memset(mockGucs, 0, sizeof(mockGucs));
    mockGucCount = 0;
    memset(mockReservedPrefix, 0, sizeof(mockReservedPrefix));
    mockReserveCalls = 0;
    mockSetCalls = 0;
    mockGetCalls = 0;
    mockLastSetCtx = -1;
    mockLastSetAct = -1;
    mockLastSetRole = InvalidOid;
    mockUsedExtApi = false;
    memset(mockLastSetName, 0, sizeof(mockLastSetName));
    memset(mockLastSetVal, 0, sizeof(mockLastSetVal));
    mockInSecRest = false;
    mockIsSuperuser = true;
    mockUserId = (Oid)10;
    process_shared_preload_libraries_in_progress = false;
}

static MockGucSlot *mockFindGuc(const char *name) {
    if (!name) return NULL;
    for (int i = 0; i < mockGucCount; i++) {
        if (mockGucs[i].used && strcmp(mockGucs[i].name, name) == 0) {
            return &mockGucs[i];
        }
    }
    return NULL;
}

void DefineCustomBoolVariable(const char *name, const char *short_desc, const char *long_desc,
                              bool *valueAddr, bool bootValue, GucContext context, int flags,
                              GucBoolCheckHook ch, GucBoolAssignHook ah, GucShowHook sh) {
    (void)ch; (void)ah; (void)sh;
    MockGucSlot *s = &mockGucs[mockGucCount++];
    memset(s, 0, sizeof(*s));
    s->used = true;
    s->kind = MOCK_GUC_BOOL;
    s->name = name;
    s->short_desc = short_desc;
    s->long_desc = long_desc;
    s->value_addr = (void *)valueAddr;
    *valueAddr = bootValue;
    s->context = context;
    s->flags = flags;
    snprintf(s->current_text, sizeof(s->current_text), "%s", bootValue ? "on" : "off");
}

void DefineCustomIntVariable(const char *name, const char *short_desc, const char *long_desc,
                             int *valueAddr, int bootValue, int minValue, int maxValue,
                             GucContext context, int flags,
                             GucIntCheckHook ch, GucIntAssignHook ah, GucShowHook sh) {
    (void)ch; (void)ah; (void)sh;
    MockGucSlot *s = &mockGucs[mockGucCount++];
    memset(s, 0, sizeof(*s));
    s->used = true;
    s->kind = MOCK_GUC_INT;
    s->name = name;
    s->short_desc = short_desc;
    s->long_desc = long_desc;
    s->value_addr = (void *)valueAddr;
    *valueAddr = bootValue;
    s->min_int = minValue;
    s->max_int = maxValue;
    s->context = context;
    s->flags = flags;
    snprintf(s->current_text, sizeof(s->current_text), "%d", bootValue);
}

void DefineCustomRealVariable(const char *name, const char *short_desc, const char *long_desc,
                              double *valueAddr, double bootValue, double minValue, double maxValue,
                              GucContext context, int flags,
                              GucRealCheckHook ch, GucRealAssignHook ah, GucShowHook sh) {
    (void)ch; (void)ah; (void)sh;
    MockGucSlot *s = &mockGucs[mockGucCount++];
    memset(s, 0, sizeof(*s));
    s->used = true;
    s->kind = MOCK_GUC_REAL;
    s->name = name;
    s->short_desc = short_desc;
    s->long_desc = long_desc;
    s->value_addr = (void *)valueAddr;
    *valueAddr = bootValue;
    s->min_real = minValue;
    s->max_real = maxValue;
    s->context = context;
    s->flags = flags;
    snprintf(s->current_text, sizeof(s->current_text), "%.6g", bootValue);
}

void DefineCustomStringVariable(const char *name, const char *short_desc, const char *long_desc,
                                char **valueAddr, const char *bootValue,
                                GucContext context, int flags,
                                GucStringCheckHook ch, GucStringAssignHook ah, GucShowHook sh) {
    (void)ch; (void)ah; (void)sh;
    MockGucSlot *s = &mockGucs[mockGucCount++];
    memset(s, 0, sizeof(*s));
    s->used = true;
    s->kind = MOCK_GUC_STRING;
    s->name = name;
    s->short_desc = short_desc;
    s->long_desc = long_desc;
    s->value_addr = (void *)valueAddr;
    s->boot_str = bootValue;
    s->str_addr_was_null_on_define = (*valueAddr == NULL);
    *valueAddr = bootValue ? strdup(bootValue) : NULL;
    s->context = context;
    s->flags = flags;
    snprintf(s->current_text, sizeof(s->current_text), "%s", bootValue ? bootValue : "");
}

void DefineCustomEnumVariable(const char *name, const char *short_desc, const char *long_desc,
                              int *valueAddr, int bootValue, const struct config_enum_entry *options,
                              GucContext context, int flags,
                              GucEnumCheckHook ch, GucEnumAssignHook ah, GucShowHook sh) {
    (void)ch; (void)ah; (void)sh;
    MockGucSlot *s = &mockGucs[mockGucCount++];
    memset(s, 0, sizeof(*s));
    s->used = true;
    s->kind = MOCK_GUC_ENUM;
    s->name = name;
    s->short_desc = short_desc;
    s->long_desc = long_desc;
    s->value_addr = (void *)valueAddr;
    *valueAddr = bootValue;
    s->enum_opts = options;
    s->context = context;
    s->flags = flags;
    const char *label = "";
    if (options) {
        for (int i = 0; options[i].name != NULL; i++) {
            if (options[i].val == bootValue) {
                label = options[i].name;
                break;
            }
        }
    }
    snprintf(s->current_text, sizeof(s->current_text), "%s", label);
}

#if PG_VERSION_NUM >= 150000
void MarkGUCPrefixReserved(const char *className) {
    mockReserveCalls++;
    snprintf(mockReservedPrefix, sizeof(mockReservedPrefix), "%s", className ? className : "");
}
#else
void EmitWarningsOnPlaceholders(const char *className) {
    mockReserveCalls++;
    snprintf(mockReservedPrefix, sizeof(mockReservedPrefix), "%s", className ? className : "");
}
#endif

const char *GetConfigOption(const char *name, bool missing_ok, bool restrict_privileged) {
    mockGetCalls++;
    MockGucSlot *s = mockFindGuc(name);
    if (s == NULL) {
        if (missing_ok) return NULL;
        mockTriggerPgError(ERRCODE_UNDEFINED_OBJECT, "unrecognized configuration parameter");
    }
    if (restrict_privileged && (s->flags & GUC_SUPERUSER_ONLY) && !superuser()) {
        snprintf(mockErrMsgBuf, sizeof(mockErrMsgBuf), "must be superuser to examine \"%s\"", name);
        mockTriggerPgError(ERRCODE_INSUFFICIENT_PRIVILEGE, mockErrMsgBuf);
    }
    return s->current_text;
}

static int mockDoSetConfigOption(const char *name, const char *value,
                                 GucContext context, GucSource source,
                                 Oid srole, GucAction action,
                                 bool changeVal, int elevel, bool is_reload, bool is_ext) {
    (void)source; (void)changeVal; (void)elevel; (void)is_reload;
    mockSetCalls++;
    mockLastSetCtx = (int)context;
    mockLastSetAct = (int)action;
    mockLastSetRole = srole;
    mockUsedExtApi = is_ext;
    snprintf(mockLastSetName, sizeof(mockLastSetName), "%s", name ? name : "");
    snprintf(mockLastSetVal, sizeof(mockLastSetVal), "%s", value ? value : "");

    MockGucSlot *s = mockFindGuc(name);
    if (s == NULL) {
        mockTriggerPgError(ERRCODE_UNDEFINED_OBJECT, "unrecognized configuration parameter");
    }
    if (s->context == PGC_SUSET && context > PGC_SUSET) {
        snprintf(mockErrMsgBuf, sizeof(mockErrMsgBuf), "permission denied to set parameter \"%s\"", name);
        mockTriggerPgError(ERRCODE_INSUFFICIENT_PRIVILEGE, mockErrMsgBuf);
    }
    if (s->context < PGC_SUSET) {
        mockTriggerPgError(ERRCODE_CANT_CHANGE_RUNTIME_PARAM, "parameter cannot be changed now");
    }
    if (s->kind == MOCK_GUC_INT) {
        int parsed = atoi(value ? value : "");
        if (parsed < s->min_int || parsed > s->max_int) {
            mockTriggerPgError(ERRCODE_INVALID_PARAMETER_VALUE, "value outside valid range");
        }
        *(int *)s->value_addr = parsed;
        snprintf(s->current_text, sizeof(s->current_text), "%d", parsed);
    } else if (s->kind == MOCK_GUC_BOOL) {
        bool bv = (value && (strcmp(value, "on") == 0 || strcmp(value, "true") == 0));
        *(bool *)s->value_addr = bv;
        snprintf(s->current_text, sizeof(s->current_text), "%s", bv ? "on" : "off");
    } else if (s->kind == MOCK_GUC_STRING) {
        char **p = (char **)s->value_addr;
        *p = value ? strdup(value) : NULL;
        snprintf(s->current_text, sizeof(s->current_text), "%s", value ? value : "");
    }
    return 1;
}

#if PG_VERSION_NUM >= 150000
int set_config_option_ext(const char *name, const char *value,
                          GucContext context, GucSource source,
                          Oid srole, GucAction action,
                          bool changeVal, int elevel, bool is_reload) {
    return mockDoSetConfigOption(name, value, context, source, srole, action, changeVal, elevel, is_reload, true);
}
int set_config_option(const char *name, const char *value,
                      GucContext context, GucSource source,
                      GucAction action, bool changeVal, int elevel, bool is_reload) {
    return mockDoSetConfigOption(name, value, context, source, InvalidOid, action, changeVal, elevel, is_reload, false);
}
#else
int set_config_option(const char *name, const char *value,
                      GucContext context, GucSource source,
                      GucAction action, bool changeVal, int elevel, bool is_reload) {
    return mockDoSetConfigOption(name, value, context, source, InvalidOid, action, changeVal, elevel, is_reload, false);
}
#endif

/* Direct C ABI inspection helpers for tests */
static int c_pg_version_num(void) { return PG_VERSION_NUM; }
static int c_guc_superuser_only(void) { return (int)GUC_SUPERUSER_ONLY; }
static int c_guc_no_show_all(void) { return (int)GUC_NO_SHOW_ALL; }
static int c_guc_no_reset_all(void) { return (int)GUC_NO_RESET_ALL; }
static int c_guc_report(void) { return (int)GUC_REPORT; }
static int c_guc_not_while_sec_rest(void) { return (int)GUC_NOT_WHILE_SEC_REST; }
static int c_guc_disallow_in_file(void) { return (int)GUC_DISALLOW_IN_FILE; }
static int c_guc_disallow_in_auto_file(void) {
#ifdef GUC_DISALLOW_IN_AUTO_FILE
    return (int)GUC_DISALLOW_IN_AUTO_FILE;
#else
    return 0;
#endif
}
static int c_ctx_postmaster(void) { return (int)PGC_POSTMASTER; }
static int c_ctx_sighup(void) { return (int)PGC_SIGHUP; }
static int c_ctx_su_backend(void) { return (int)PGC_SU_BACKEND; }
static int c_ctx_backend(void) { return (int)PGC_BACKEND; }
static int c_ctx_suset(void) { return (int)PGC_SUSET; }
static int c_ctx_userset(void) { return (int)PGC_USERSET; }
static int c_action_set(void) { return (int)GUC_ACTION_SET; }
static int c_action_local(void) { return (int)GUC_ACTION_LOCAL; }

static void mock_set_security_context(bool is_super, bool in_sec_rest, Oid uid) {
    mockIsSuperuser = is_super;
    mockInSecRest = in_sec_rest;
    mockUserId = uid;
}
static void mock_set_preload(bool active) {
    process_shared_preload_libraries_in_progress = active;
}
static int mock_guc_count(void) { return mockGucCount; }
static int mock_guc_flags_at(int idx) { return mockGucs[idx].flags; }
static int mock_guc_ctx_at(int idx) { return (int)mockGucs[idx].context; }
static bool mock_str_addr_was_null(int idx) { return mockGucs[idx].str_addr_was_null_on_define; }
static const char *mock_guc_boot_str(int idx) { return mockGucs[idx].boot_str; }
static const char *mock_guc_short_desc(int idx) { return mockGucs[idx].short_desc; }
static const char *mock_guc_long_desc(int idx) { return mockGucs[idx].long_desc; }
static int mock_reserve_calls(void) { return mockReserveCalls; }
static const char *mock_reserved_prefix(void) { return mockReservedPrefix; }
static int mock_set_calls(void) { return mockSetCalls; }
static int mock_last_set_ctx(void) { return mockLastSetCtx; }
static int mock_last_set_act(void) { return mockLastSetAct; }
static Oid mock_last_set_role(void) { return mockLastSetRole; }
static bool mock_used_ext_api(void) { return mockUsedExtApi; }
""".}

proc mockResetState() {.importc: "mockResetState", nodecl.}
proc cPgVersionNum(): cint {.importc: "c_pg_version_num", nodecl.}
proc cGucSuperuserOnly(): cint {.importc: "c_guc_superuser_only", nodecl.}
proc cGucNoShowAll(): cint {.importc: "c_guc_no_show_all", nodecl.}
proc cGucNoResetAll(): cint {.importc: "c_guc_no_reset_all", nodecl.}
proc cGucReport(): cint {.importc: "c_guc_report", nodecl.}
proc cGucNotWhileSecRest(): cint {.importc: "c_guc_not_while_sec_rest", nodecl.}
proc cGucDisallowInFile(): cint {.importc: "c_guc_disallow_in_file", nodecl.}
proc cGucDisallowInAutoFile(): cint {.importc: "c_guc_disallow_in_auto_file", nodecl.}
proc cCtxPostmaster(): cint {.importc: "c_ctx_postmaster", nodecl.}
proc cCtxSighup(): cint {.importc: "c_ctx_sighup", nodecl.}
proc cCtxSuBackend(): cint {.importc: "c_ctx_su_backend", nodecl.}
proc cCtxBackend(): cint {.importc: "c_ctx_backend", nodecl.}
proc cCtxSuset(): cint {.importc: "c_ctx_suset", nodecl.}
proc cCtxUserset(): cint {.importc: "c_ctx_userset", nodecl.}
proc cActionSet(): cint {.importc: "c_action_set", nodecl.}
proc cActionLocal(): cint {.importc: "c_action_local", nodecl.}
proc mockSetSecCtx(isSuper, inSecRest: bool, uid: uint32) {.importc: "mock_set_security_context", nodecl.}
proc mockSetPreload(active: bool) {.importc: "mock_set_preload", nodecl.}
proc mockGucCount(): cint {.importc: "mock_guc_count", nodecl.}
proc mockGucFlagsAt(idx: cint): cint {.importc: "mock_guc_flags_at", nodecl.}
proc mockGucCtxAt(idx: cint): cint {.importc: "mock_guc_ctx_at", nodecl.}
proc mockStrAddrWasNull(idx: cint): bool {.importc: "mock_str_addr_was_null", nodecl.}
proc mockGucBootStr(idx: cint): cstring {.importc: "mock_guc_boot_str", nodecl.}
proc mockGucShortDesc(idx: cint): cstring {.importc: "mock_guc_short_desc", nodecl.}
proc mockGucLongDesc(idx: cint): cstring {.importc: "mock_guc_long_desc", nodecl.}
proc mockReserveCalls(): cint {.importc: "mock_reserve_calls", nodecl.}
proc mockReservedPrefix(): cstring {.importc: "mock_reserved_prefix", nodecl.}
proc mockSetCalls(): cint {.importc: "mock_set_calls", nodecl.}
proc mockLastSetCtx(): cint {.importc: "mock_last_set_ctx", nodecl.}
proc mockLastSetAct(): cint {.importc: "mock_last_set_act", nodecl.}
proc mockLastSetRole(): uint32 {.importc: "mock_last_set_role", nodecl.}
proc mockUsedExtApi(): bool {.importc: "mock_used_ext_api", nodecl.}

type
  TestMode = enum
    tmFast = "fast"
    tmSafe = "safe"

  TestCustomLabelMode = enum
    tclAlpha = 1
    tclBeta = 2

suite "Pgxcrown - Secure GUC Support Suite":

  setup:
    mockResetState()

  test "C ABI GUC flag & context getters match target PostgreSQL version headers":
    check gucFlagSuperuserOnly() == cGucSuperuserOnly()
    check gucFlagNoShowAll() == cGucNoShowAll()
    check gucFlagNoResetAll() == cGucNoResetAll()
    check gucFlagReport() == cGucReport()
    check gucFlagNotWhileSecRest() == cGucNotWhileSecRest()
    check gucFlagDisallowInFile() == cGucDisallowInFile()
    check gucFlagDisallowInAutoFile() == cGucDisallowInAutoFile()

    if cPgVersionNum() >= 160000:
      check gucFlagSuperuserOnly() == 0x0400'i32
    else:
      check gucFlagSuperuserOnly() == 0x0100'i32

    let suFlags = toCFlags({}, superuserOnly = true)
    check (suFlags and gucFlagSuperuserOnly()) != 0
    check (suFlags and gucFlagNoShowAll()) != 0

    check toCContext(gcPostmaster) == cCtxPostmaster()
    check toCContext(gcSighup) == cCtxSighup()
    check toCContext(gcSuBackend) == cCtxSuBackend()
    check toCContext(gcBackend) == cCtxBackend()
    check toCContext(gcSuset) == cCtxSuset()
    check toCContext(gcUserset) == cCtxUserset()

  test "Pure-Nim validateGucName accepts valid <prefix>.<param> and rejects malformed/SQL-injection names":
    validateGucName("gucsec.max_items")
    validateGucName("a.b")
    validateGucName("my_ext_2.param_99", "my_ext_2")
    let maxSeg = repeat('a', 63)
    validateGucName(maxSeg & "." & maxSeg, maxSeg)

    let invalidFormatNames = [
      "",
      ".",
      "gucsec.",
      ".param",
      "no_dot",
      "a.b.c",
      "1abc.def",
      "abc.1def",
      "_abc.def",
      "abc._def",
      "GucSec.max_items",
      "gucsec.MaxItems",
      "gucsec.bad space",
      "gucsec.bad\tspace",
      "gucsec.bad\nline",
      "gucsec.bad'quote",
      "gucsec.bad\"quote",
      "gucsec.bad;drop",
      "gucsec.bad--comment",
      "gucsec.bad\0nul",
      repeat('a', 64) & ".b",
      "a." & repeat('b', 64)
    ]
    for bad in invalidFormatNames:
      expect(ValueError):
        validateGucName(bad)

  test "validateGucName enforces expectedPrefix with SQLSTATE 42501":
    validateGucName("gucsec.max_items", "gucsec")
    for cross in ["other.max_items", "gucsec_extra.max_items", "gucse.max_items"]:
      var caught42501 = false
      try:
        validateGucName(cross, "gucsec")
      except PgError as e:
        caught42501 = (unpackSqlState(e.sqlerrcode) == "42501")
      check caught42501

  test "Core & security-critical PostgreSQL GUC blocklist rejects all protected names/prefixes":
    let blockedSamples = [
      "pg", "pg.secret",
      "postgres", "postgres.admin",
      "postgresql", "postgresql.conf",
      "shared", "shared.buf", "shared_buffers",
      "shared_preload_libraries",
      "session_preload_libraries",
      "local_preload_libraries",
      "dynamic_library_path",
      "ssl", "ssl.enabled", "ssl_cert_file",
      "hba_file", "ident_file", "config_file", "data_directory",
      "log", "log.level", "log_statement", "logging_collector",
      "archive", "archive.mode", "archive_command",
      "restore_command", "listen_addresses", "search_path",
      "role", "session_authorization", "row_security",
      "allow_system_table_mods", "ignore_system_indexes",
      "jit", "jit.enabled", "jit_above_cost",
      "LOG_STATEMENT", "Search_Path"
    ]
    for b in blockedSamples:
      check isBlockedCoreGuc(b) == true
      var caught42501 = false
      try:
        validateGucName(b)
      except PgError as e:
        caught42501 = (unpackSqlState(e.sqlerrcode) == "42501")
      check caught42501

    check isBlockedCoreGuc("gucsec.max_items") == false
    check isBlockedCoreGuc("pgx_test.enabled") == false
    check isBlockedCoreGuc("myext.log_level") == false

  test "GucVar persistent storage via real_calloc survives ARC copies and nil string reads":
    mockSetPreload(true)
    var gBool = defineGucBool("gucsec.flag", "Short bool", "", true)
    check gBool.context == gcSuset
    check gBool.get() == true
    check mockGucCtxAt(0) == cCtxSuset()

    var gInt = defineGucInt("gucsec.max_items", "Max items", "Bounds test", 42, 1, 1000, context = gcUserset)
    check gInt.get() == 42'i32
    let gIntAddrBefore = gInt.storage
    let gIntCopy = gInt
    var gIntMoved = gIntCopy
    check gIntMoved.storage == gIntAddrBefore
    check gIntMoved.get() == 42'i32

    var gReal = defineGucReal("gucsec.ratio", "Ratio", "", 0.5, 0.0, 1.0)
    check abs(gReal.get() - 0.5) < 1e-9

    # Create transient Nim strings for bootValue & descriptions and ensure C pointers remain valid
    var gStr: GucVar[string]
    block:
      var tmpBoot = "boot_" & $123
      var tmpShort = "short_" & $456
      var tmpLong = "long_" & $789
      gStr = defineGucString("gucsec.secret_key", tmpShort, tmpLong, tmpBoot, context = gcSuset, superuserOnly = true)
    GC_fullCollect()
    check mockStrAddrWasNull(3) == true
    check $mockGucBootStr(3) == "boot_123"
    check $mockGucShortDesc(3) == "short_456"
    check $mockGucLongDesc(3) == "long_789"
    check (mockGucFlagsAt(3) and gucFlagSuperuserOnly()) != 0
    check (mockGucFlagsAt(3) and gucFlagNoShowAll()) != 0
    check gStr.get() == "boot_123"

    # Simulate nil *valueAddr on string GucVar (safe handling)
    let savedPtr = cast[ptr cstring](gStr.storage)[]
    cast[ptr cstring](gStr.storage)[] = nil
    check gStr.get() == ""
    cast[ptr cstring](gStr.storage)[] = savedPtr

    # Uninitialized GucVar raises ValueError safely
    var uninit: GucVar[int32]
    expect(ValueError):
      discard uninit.get()

  test "Enum config_enum_entry table builds persistent NULL-terminated array and defines enum GUC":
    let tbl = buildPersistentEnumEntries[TestCustomLabelMode](@[
      ("alpha", tclAlpha, false),
      ("beta", tclBeta, true)
    ])
    let arr = cast[ptr UncheckedArray[ConfigEnumEntry]](tbl)
    check $arr[0].name == "alpha"
    check arr[0].val == 1
    check arr[0].hidden == false
    check $arr[1].name == "beta"
    check arr[1].val == 2
    check arr[1].hidden == true
    check arr[2].name == nil
    check arr[2].val == 0
    check arr[2].hidden == false
    freePersistentEnumEntries(tbl)

    let gMode = defineGucEnum("gucsec.mode", "Mode", "", tmSafe, context = gcSuset)
    check gMode.get() == tmSafe
    check gMode.enumTable != nil
    let modeArr = cast[ptr UncheckedArray[ConfigEnumEntry]](gMode.enumTable)
    check $modeArr[0].name == "fast"
    check $modeArr[1].name == "safe"
    check modeArr[2].name == nil

  test "Constructor validation: bounds, superuserOnly+gcUserset, gcPostmaster preload, reserveGucPrefix":
    expect(ValueError):
      discard defineGucInt("gucsec.bad_range", "Bad", "", 5, 10, 1)
    expect(ValueError):
      discard defineGucInt("gucsec.bad_boot", "Bad", "", 20, 1, 10)
    expect(ValueError):
      discard defineGucReal("gucsec.bad_real_range", "Bad", "", 0.5, 1.0, 0.0)
    expect(ValueError):
      discard defineGucReal("gucsec.bad_real_nan", "Bad", "", NaN, 0.0, 1.0)
    expect(ValueError):
      discard defineGucReal("gucsec.bad_real_inf", "Bad", "", Inf, 0.0, 1.0)
    expect(ValueError):
      discard defineGucBool("gucsec.bad_su_ctx", "Bad", "", false, context = gcUserset, superuserOnly = true)
    expect(ValueError):
      discard defineGucString("gucsec.bad_nul_boot", "Bad", "", "abc\0def")

    mockSetPreload(false)
    expect(ValueError):
      discard defineGucInt("gucsec.pm_only", "PM", "", 1, 1, 10, context = gcPostmaster)
    mockSetPreload(true)
    let gPm = defineGucInt("gucsec.pm_only", "PM", "", 1, 1, 10, context = gcPostmaster)
    check gPm.get() == 1'i32

    reserveGucPrefix("gucsec")
    check mockReserveCalls() == 1
    check $mockReservedPrefix() == "gucsec"

    for badPrefix in ["pg", "postgres", "log"]:
      var caught42501 = false
      try:
        reserveGucPrefix(badPrefix)
      except PgError as e:
        caught42501 = (unpackSqlState(e.sqlerrcode) == "42501")
      check caught42501

  test "Runtime RBAC getGuc and setGuc enforce permissions, InSecurityRestrictedOperation, readOnly, and PG 15+ ACL API":
    var gUser = defineGucInt("gucsec.max_items", "Max", "", 10, 1, 1000, context = gcUserset)
    let gAdmin = defineGucBool("gucsec.admin_flag", "Admin", "", false, context = gcSuset)
    discard defineGucString("gucsec.secret_key", "Secret", "", "s3cr3t", context = gcSuset, superuserOnly = true)
    let gRo = defineGucInt("gucsec.ro_val", "Read-only", "", 7, 1, 10, context = gcSuset, readOnly = true)

    # Superuser can read all and missing returns none
    mockSetSecCtx(isSuper = true, inSecRest = false, uid = 10'u32)
    check getGuc("gucsec.max_items") == some("10")
    check getGuc("gucsec.secret_key") == some("s3cr3t")
    check getGuc("gucsec.nonexistent") == none(string)

    expect(ValueError):
      discard getGuc("bad;name")
    expect(ValueError):
      discard getGuc("gucsec.a\0b")

    # Non-superuser cannot read superuserOnly GUC (PG raises 42501 -> PgError)
    mockSetSecCtx(isSuper = false, inSecRest = false, uid = 16384'u32)
    check getGuc("gucsec.max_items") == some("10")
    var readDenied = false
    try:
      discard getGuc("gucsec.secret_key")
    except PgError as e:
      readDenied = (unpackSqlState(e.sqlerrcode) == "42501")
    check readDenied

    # Non-superuser CAN set gcUserset GUC; verify PGC_USERSET & GUC_ACTION_LOCAL
    setGuc("gucsec.max_items", "42", isLocal = true, allowedPrefix = "gucsec")
    check gUser.get() == 42'i32
    check mockLastSetCtx() == cCtxUserset()
    check mockLastSetAct() == cActionLocal()
    if cPgVersionNum() >= 150000:
      check mockUsedExtApi() == true
      check mockLastSetRole() == 16384'u32
    else:
      check mockUsedExtApi() == false

    # Non-superuser CANNOT set gcSuset GUC
    var setDenied = false
    try:
      setGuc("gucsec.admin_flag", "on", isLocal = true, allowedPrefix = "gucsec")
    except PgError as e:
      setDenied = (unpackSqlState(e.sqlerrcode) == "42501")
    check setDenied
    check gAdmin.get() == false

    # SECURITY CRITICAL: Even if superuser() is true, InSecurityRestrictedOperation() MUST restrict ctx to PGC_USERSET!
    mockSetSecCtx(isSuper = true, inSecRest = true, uid = 10'u32)
    var secRestDenied = false
    try:
      setGuc("gucsec.admin_flag", "on", isLocal = false)
    except PgError as e:
      secRestDenied = (unpackSqlState(e.sqlerrcode) == "42501")
    check secRestDenied
    check mockLastSetCtx() == cCtxUserset()
    check mockLastSetAct() == cActionSet()

    # Normal superuser (not in security-restricted operation) uses PGC_SUSET
    mockSetSecCtx(isSuper = true, inSecRest = false, uid = 10'u32)
    setGuc("gucsec.admin_flag", "on", isLocal = false)
    check mockLastSetCtx() == cCtxSuset()
    check mockLastSetAct() == cActionSet()
    check gAdmin.get() == true

    # Core GUC blocklist, prefix enforcement, NUL safety, and readOnly MUST fail BEFORE touching C!
    let callsBefore = mockSetCalls()
    var coreBlocked = false
    try:
      setGuc("log_statement", "none")
    except PgError as e:
      coreBlocked = (unpackSqlState(e.sqlerrcode) == "42501")
    check coreBlocked
    check mockSetCalls() == callsBefore

    var prefixBlocked = false
    try:
      setGuc("other.param", "1", allowedPrefix = "gucsec")
    except PgError as e:
      prefixBlocked = (unpackSqlState(e.sqlerrcode) == "42501")
    check prefixBlocked
    check mockSetCalls() == callsBefore

    expect(ValueError):
      setGuc("gucsec.max_items", "bad\0val")
    check mockSetCalls() == callsBefore

    var roBlocked = false
    try:
      setGuc("gucsec.ro_val", "9")
    except PgError as e:
      roBlocked = (unpackSqlState(e.sqlerrcode) == "42501")
    check roBlocked
    check mockSetCalls() == callsBefore

    var roVarBlocked = false
    try:
      gRo.value = 9'i32
    except PgError as e:
      roVarBlocked = (unpackSqlState(e.sqlerrcode) == "42501")
    check roVarBlocked
    check gRo.get() == 7'i32
    check mockSetCalls() == callsBefore

    # GucVar.value= updates through setGuc safely
    gUser.value = 77'i32
    check gUser.get() == 77'i32
