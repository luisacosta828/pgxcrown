#ifndef PGXCROWN_PGX_HOOKS_H
#define PGXCROWN_PGX_HOOKS_H

#include "postgres.h"
#include "executor/executor.h"
#include "tcop/utility.h"
#include "parser/analyze.h"
#include "utils/elog.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "nodes/value.h"
#include "utils/palloc.h"
#include <signal.h>
#include <string.h>

/* ============================================================================
 * Normalized Command Type across PostgreSQL 14 - 18
 * (PG 15 inserted CMD_MERGE between CMD_DELETE and CMD_UTILITY)
 * ============================================================================ */
typedef enum PgxCmdType {
    PGX_CMD_UNKNOWN = 0,
    PGX_CMD_SELECT  = 1,
    PGX_CMD_UPDATE  = 2,
    PGX_CMD_INSERT  = 3,
    PGX_CMD_DELETE  = 4,
    PGX_CMD_MERGE   = 5,
    PGX_CMD_UTILITY = 6,
    PGX_CMD_NOTHING = 7
} PgxCmdType;

static inline int32 pgx_normalize_cmd_type(CmdType op) {
    switch (op) {
        case CMD_SELECT:  return (int32)PGX_CMD_SELECT;
        case CMD_UPDATE:  return (int32)PGX_CMD_UPDATE;
        case CMD_INSERT:  return (int32)PGX_CMD_INSERT;
        case CMD_DELETE:  return (int32)PGX_CMD_DELETE;
#if PG_VERSION_NUM >= 150000
        case CMD_MERGE:   return (int32)PGX_CMD_MERGE;
#endif
        case CMD_UTILITY: return (int32)PGX_CMD_UTILITY;
        case CMD_NOTHING: return (int32)PGX_CMD_NOTHING;
        default:          return (int32)PGX_CMD_UNKNOWN;
    }
}

static inline const char *pgx_cmd_type_name(int32 norm_op) {
    switch (norm_op) {
        case PGX_CMD_SELECT:  return "SELECT";
        case PGX_CMD_UPDATE:  return "UPDATE";
        case PGX_CMD_INSERT:  return "INSERT";
        case PGX_CMD_DELETE:  return "DELETE";
        case PGX_CMD_MERGE:   return "MERGE";
        case PGX_CMD_UTILITY: return "UTILITY";
        case PGX_CMD_NOTHING: return "NOTHING";
        default:              return "UNKNOWN";
    }
}

/* ============================================================================
 * C <-> Nim Dispatcher Function Pointer Typedefs
 * ============================================================================ */
typedef void (*PgxNimExecStartFn)(QueryDesc *qd, int32 eflags);
typedef void (*PgxNimExecRunFn)(QueryDesc *qd, int32 dir, uint64 count, bool execute_once);
typedef void (*PgxNimExecQueryFn)(QueryDesc *qd);
typedef void (*PgxNimProcessUtilityFn)(
    PlannedStmt *pstmt,
    char *queryString,
    bool readOnlyTree,
    int32 context,
    void *params,
    void *queryEnv,
    void *dest,
    void *qc);
typedef void (*PgxNimEmitLogFn)(ErrorData *edata);
typedef void (*PgxNimPostParseFn)(ParseState *pstate, Query *query, JumbleState *jstate);

/* ============================================================================
 * Stateless QueryDesc / ParseState / Query / PlannedStmt / DropStmt Accessors
 * ============================================================================ */
static inline const char *pgx_qdesc_source_text(QueryDesc *qd) {
    if (qd == NULL) return NULL;
    return qd->sourceText;
}

static inline int32 pgx_qdesc_operation(QueryDesc *qd) {
    if (qd == NULL) return (int32)PGX_CMD_UNKNOWN;
    return pgx_normalize_cmd_type(qd->operation);
}

static inline const char *pgx_qdesc_operation_name(QueryDesc *qd) {
    return pgx_cmd_type_name(pgx_qdesc_operation(qd));
}

static inline uint64 pgx_qdesc_rows_processed(QueryDesc *qd) {
    if (qd == NULL || qd->estate == NULL) return 0;
#if PG_VERSION_NUM >= 180000
    return (qd->estate->es_total_processed > qd->estate->es_processed)
        ? qd->estate->es_total_processed
        : qd->estate->es_processed;
#else
    return qd->estate->es_processed;
#endif
}

static inline int64 pgx_qdesc_query_id(QueryDesc *qd) {
    if (qd == NULL || qd->plannedstmt == NULL) return 0;
    return (int64)qd->plannedstmt->queryId;
}

static inline bool pgx_qdesc_has_estate(QueryDesc *qd) {
    return qd != NULL && qd->estate != NULL;
}

static inline const char *pgx_pstate_source_text(ParseState *pstate) {
    if (pstate == NULL) return NULL;
    return pstate->p_sourcetext;
}

static inline int32 pgx_query_operation(Query *query) {
    if (query == NULL) return (int32)PGX_CMD_UNKNOWN;
    return pgx_normalize_cmd_type(query->commandType);
}

static inline int64 pgx_query_id(Query *query) {
    if (query == NULL) return 0;
    return (int64)query->queryId;
}

static inline int32 pgx_utility_node_tag(PlannedStmt *pstmt) {
    if (pstmt == NULL || pstmt->utilityStmt == NULL) {
        return (int32)T_Invalid;
    }
    return (int32)nodeTag(pstmt->utilityStmt);
}

static inline const char *pgx_utility_tag_name(PlannedStmt *pstmt) {
    if (pstmt == NULL || pstmt->utilityStmt == NULL) {
        return "None";
    }
    switch (nodeTag(pstmt->utilityStmt)) {
        case T_DropStmt:            return "DropStmt";
        case T_CreateStmt:          return "CreateStmt";
        case T_AlterTableStmt:      return "AlterTableStmt";
        case T_TruncateStmt:        return "TruncateStmt";
        case T_IndexStmt:           return "IndexStmt";
        case T_ViewStmt:            return "ViewStmt";
        case T_CopyStmt:            return "CopyStmt";
        case T_CreateFunctionStmt:  return "CreateFunctionStmt";
        case T_CreateExtensionStmt: return "CreateExtensionStmt";
        case T_AlterExtensionStmt:  return "AlterExtensionStmt";
        case T_TransactionStmt:     return "TransactionStmt";
        case T_DoStmt:              return "DoStmt";
        case T_VariableSetStmt:     return "VariableSetStmt";
        case T_VariableShowStmt:    return "VariableShowStmt";
        case T_ExplainStmt:         return "ExplainStmt";
        case T_VacuumStmt:          return "VacuumStmt";
        case T_GrantStmt:           return "GrantStmt";
        case T_GrantRoleStmt:       return "GrantRoleStmt";
        case T_CreateSchemaStmt:    return "CreateSchemaStmt";
        case T_CreateRoleStmt:      return "CreateRoleStmt";
        case T_AlterRoleStmt:       return "AlterRoleStmt";
        case T_DropRoleStmt:        return "DropRoleStmt";
        case T_LockStmt:            return "LockStmt";
        case T_NotifyStmt:          return "NotifyStmt";
        case T_ListenStmt:          return "ListenStmt";
        case T_UnlistenStmt:        return "UnlistenStmt";
        case T_CommentStmt:         return "CommentStmt";
        case T_RefreshMatViewStmt:  return "RefreshMatViewStmt";
        case T_CreateSeqStmt:       return "CreateSeqStmt";
        case T_AlterSeqStmt:        return "AlterSeqStmt";
        case T_RenameStmt:          return "RenameStmt";
        case T_CreateTrigStmt:      return "CreateTrigStmt";
        case T_CreateDomainStmt:    return "CreateDomainStmt";
        case T_CompositeTypeStmt:   return "CompositeTypeStmt";
        case T_CreateEnumStmt:      return "CreateEnumStmt";
        case T_PrepareStmt:         return "PrepareStmt";
        case T_ExecuteStmt:         return "ExecuteStmt";
        case T_DeallocateStmt:      return "DeallocateStmt";
        case T_CallStmt:            return "CallStmt";
        case T_CreatedbStmt:        return "CreatedbStmt";
        case T_DropdbStmt:          return "DropdbStmt";
        case T_DropOwnedStmt:       return "DropOwnedStmt";
        case T_ReassignOwnedStmt:   return "ReassignOwnedStmt";
        default:                    return "Other";
    }
}

static inline bool pgx_utility_is_drop_stmt(PlannedStmt *pstmt) {
    return pstmt != NULL && pstmt->utilityStmt != NULL && IsA(pstmt->utilityStmt, DropStmt);
}

static inline int32 pgx_utility_drop_remove_type(PlannedStmt *pstmt) {
    if (!pgx_utility_is_drop_stmt(pstmt)) return -1;
    return (int32)((const DropStmt *)pstmt->utilityStmt)->removeType;
}

static inline bool pgx_utility_is_drop_table(PlannedStmt *pstmt) {
    if (!pgx_utility_is_drop_stmt(pstmt)) return false;
    return ((const DropStmt *)pstmt->utilityStmt)->removeType == OBJECT_TABLE;
}

typedef struct PgxCStringBuf {
    char *data;
    size_t len;
    size_t cap;
} PgxCStringBuf;

static inline void pgx_csbuf_init(PgxCStringBuf *b, size_t init_cap) {
    b->cap = init_cap > 16 ? init_cap : 64;
    b->len = 0;
    b->data = (char *)palloc(b->cap);
    b->data[0] = '\0';
}

static inline void pgx_csbuf_ensure(PgxCStringBuf *b, size_t extra) {
    size_t needed = b->len + extra + 1;
    size_t new_cap;
    if (needed <= b->cap) return;
    new_cap = b->cap * 2;
    while (new_cap < needed) {
        new_cap *= 2;
    }
    b->data = (char *)repalloc(b->data, new_cap);
    b->cap = new_cap;
}

static inline void pgx_csbuf_append_n(PgxCStringBuf *b, const char *s, size_t n) {
    if (s == NULL || n == 0) return;
    pgx_csbuf_ensure(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static inline void pgx_csbuf_append_str(PgxCStringBuf *b, const char *s) {
    if (s == NULL || s[0] == '\0') return;
    pgx_csbuf_append_n(b, s, strlen(s));
}

static inline void pgx_csbuf_append_char(PgxCStringBuf *b, char ch) {
    pgx_csbuf_ensure(b, 1);
    b->data[b->len++] = ch;
    b->data[b->len] = '\0';
}

static inline void pgx_append_name_list(PgxCStringBuf *b, List *names) {
    ListCell *nc = NULL;
    bool first = true;
    if (names == NIL) return;
    foreach(nc, names) {
        Node *item = (Node *)lfirst(nc);
        if (item != NULL && nodeTag(item) == T_String) {
            const char *part = strVal(item);
            if (part != NULL && part[0] != '\0') {
                if (!first) pgx_csbuf_append_char(b, '.');
                pgx_csbuf_append_str(b, part);
                first = false;
            }
        }
    }
}

static inline char *pgx_utility_drop_targets_csv(PlannedStmt *pstmt) {
    PgxCStringBuf b;
    DropStmt *drop;
    ListCell *cell = NULL;
    bool first_obj = true;

    pgx_csbuf_init(&b, 128);
    if (!pgx_utility_is_drop_stmt(pstmt)) {
        return b.data;
    }
    drop = (DropStmt *)pstmt->utilityStmt;
    if (drop->objects == NIL) {
        return b.data;
    }
    foreach(cell, drop->objects) {
        Node *obj = (Node *)lfirst(cell);
        size_t mark = b.len;
        if (obj == NULL) continue;

        if (!first_obj) {
            pgx_csbuf_append_char(&b, ',');
        }
        if (IsA(obj, List)) {
            pgx_append_name_list(&b, (List *)obj);
        } else if (nodeTag(obj) == T_String) {
            pgx_csbuf_append_str(&b, strVal(obj));
        } else if (IsA(obj, TypeName)) {
            pgx_append_name_list(&b, ((TypeName *)obj)->names);
        } else if (IsA(obj, ObjectWithArgs)) {
            pgx_append_name_list(&b, ((ObjectWithArgs *)obj)->objname);
        } else if (IsA(obj, RangeVar)) {
            RangeVar *rv = (RangeVar *)obj;
            if (rv->schemaname != NULL && rv->schemaname[0] != '\0') {
                pgx_csbuf_append_str(&b, rv->schemaname);
                pgx_csbuf_append_char(&b, '.');
            }
            if (rv->relname != NULL) {
                pgx_csbuf_append_str(&b, rv->relname);
            }
        }

        if (b.len > mark + (first_obj ? 0 : 1)) {
            first_obj = false;
        } else {
            b.len = mark;
            b.data[b.len] = '\0';
        }
    }
    return b.data;
}

/* ============================================================================
 * External Declarations for Single-Definition Hook Installer / Trampoline API
 * (Implemented once in registry.nim)
 * ============================================================================ */
extern void pgx_install_executor_start_hook(PgxNimExecStartFn pre_fn, PgxNimExecStartFn post_fn);
extern void pgx_uninstall_executor_start_hook(void);
extern bool pgx_is_executor_start_hook_installed(void);

extern void pgx_install_executor_run_hook(PgxNimExecRunFn pre_fn, PgxNimExecRunFn post_fn);
extern void pgx_uninstall_executor_run_hook(void);
extern bool pgx_is_executor_run_hook_installed(void);

extern void pgx_install_executor_finish_hook(PgxNimExecQueryFn pre_fn, PgxNimExecQueryFn post_fn);
extern void pgx_uninstall_executor_finish_hook(void);
extern bool pgx_is_executor_finish_hook_installed(void);

extern void pgx_install_executor_end_hook(PgxNimExecQueryFn pre_fn, PgxNimExecQueryFn post_fn);
extern void pgx_uninstall_executor_end_hook(void);
extern bool pgx_is_executor_end_hook_installed(void);

extern void pgx_install_process_utility_hook(PgxNimProcessUtilityFn pre_fn, PgxNimProcessUtilityFn post_fn);
extern void pgx_uninstall_process_utility_hook(void);
extern bool pgx_is_process_utility_hook_installed(void);

extern void pgx_install_emit_log_hook(PgxNimEmitLogFn pre_fn, PgxNimEmitLogFn post_fn);
extern void pgx_uninstall_emit_log_hook(void);
extern bool pgx_is_emit_log_hook_installed(void);

extern void pgx_install_post_parse_analyze_hook(PgxNimPostParseFn pre_fn, PgxNimPostParseFn post_fn);
extern void pgx_uninstall_post_parse_analyze_hook(void);
extern bool pgx_is_post_parse_analyze_hook_installed(void);

#endif /* PGXCROWN_PGX_HOOKS_H */
