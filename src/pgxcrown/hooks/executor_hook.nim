## =============================================================================
## Pgxcrown Executor Hook Types & Cross-Version QueryDesc Accessors (PG 14-18)
## =============================================================================

import std/os

const PgxExecHookCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxExecHookCHeadersDir).}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "executor/executor.h"
#include "pgx_hooks.h"
""".}

type
  QueryDescObj* {.importc: "QueryDesc", header: "executor/execdesc.h", incompleteStruct.} = object
  QueryDescPtr* = ptr QueryDescObj

  ScanDirection* {.size: sizeof(cint).} = enum
    BackwardScanDirection = -1
    NoMovementScanDirection = 0
    ForwardScanDirection = 1

  PgxCmdType* {.size: sizeof(cint).} = enum
    ## Normalized CmdType independent of PostgreSQL 14 vs 15+ (CMD_MERGE insertion)
    pgxCmdUnknown = 0
    pgxCmdSelect  = 1
    pgxCmdUpdate  = 2
    pgxCmdInsert  = 3
    pgxCmdDelete  = 4
    pgxCmdMerge   = 5
    pgxCmdUtility = 6
    pgxCmdNothing = 7

  ExecutorQueryInfo* = object
    ## Lightweight POD handle passed to composable Executor* callbacks
    raw*: QueryDescPtr

  ExecutorStartHook*  = proc(info: ExecutorQueryInfo, eflags: cint)
  ExecutorRunHook*    = proc(info: ExecutorQueryInfo, direction: ScanDirection, count: uint64, executeOnce: bool)
  ExecutorFinishHook* = proc(info: ExecutorQueryInfo)
  ExecutorEndHook*    = proc(info: ExecutorQueryInfo)

  ExecutorStartCallback*  = ExecutorStartHook
  ExecutorRunCallback*    = ExecutorRunHook
  ExecutorFinishCallback* = ExecutorFinishHook
  ExecutorEndCallback*    = ExecutorEndHook

{.push header: "pgx_hooks.h".}
proc pgxQdescSourceText(qd: QueryDescPtr): cstring {.importc: "pgx_qdesc_source_text".}
proc pgxQdescOperation(qd: QueryDescPtr): int32 {.importc: "pgx_qdesc_operation".}
proc pgxQdescOperationName(qd: QueryDescPtr): cstring {.importc: "pgx_qdesc_operation_name".}
proc pgxQdescRowsProcessed(qd: QueryDescPtr): uint64 {.importc: "pgx_qdesc_rows_processed".}
proc pgxQdescQueryId(qd: QueryDescPtr): int64 {.importc: "pgx_qdesc_query_id".}
proc pgxQdescHasEstate(qd: QueryDescPtr): bool {.importc: "pgx_qdesc_has_estate".}
{.pop.}

proc `$`*(op: PgxCmdType): string {.inline.} =
  case op
  of pgxCmdUnknown: "UNKNOWN"
  of pgxCmdSelect:  "SELECT"
  of pgxCmdUpdate:  "UPDATE"
  of pgxCmdInsert:  "INSERT"
  of pgxCmdDelete:  "DELETE"
  of pgxCmdMerge:   "MERGE"
  of pgxCmdUtility: "UTILITY"
  of pgxCmdNothing: "NOTHING"

proc sourceText*(qd: QueryDescPtr): string {.inline.} =
  ## Safely returns the query source text from QueryDesc (or "" if nil).
  let s = pgxQdescSourceText(qd)
  if s == nil: "" else: $s

proc operation*(qd: QueryDescPtr): PgxCmdType {.inline.} =
  ## Safely returns the normalized PgxCmdType from QueryDesc across PG 14-18.
  let code = pgxQdescOperation(qd)
  if code >= ord(low(PgxCmdType)).int32 and code <= ord(high(PgxCmdType)).int32:
    PgxCmdType(code)
  else:
    pgxCmdUnknown

proc operationName*(qd: QueryDescPtr): string {.inline.} =
  ## Returns the canonical uppercase operation name (SELECT, INSERT, UPDATE, DELETE, MERGE, UTILITY, etc.).
  let s = pgxQdescOperationName(qd)
  if s == nil: "UNKNOWN" else: $s

proc rowsProcessed*(qd: QueryDescPtr): uint64 {.inline.} =
  ## Safely returns processed tuple count from QueryDesc->estate across PG 14-18 (0 if NULL).
  pgxQdescRowsProcessed(qd)

proc queryId*(qd: QueryDescPtr): int64 {.inline.} =
  ## Safely returns QueryDesc->plannedstmt->queryId across PG 14-18 (0 if NULL).
  pgxQdescQueryId(qd)

proc hasEstate*(qd: QueryDescPtr): bool {.inline.} =
  ## Returns true when QueryDesc and QueryDesc->estate are both non-NULL.
  pgxQdescHasEstate(qd)

proc sourceText*(info: ExecutorQueryInfo): string {.inline.} = info.raw.sourceText()
proc operation*(info: ExecutorQueryInfo): PgxCmdType {.inline.} = info.raw.operation()
proc operationName*(info: ExecutorQueryInfo): string {.inline.} = info.raw.operationName()
proc rowsProcessed*(info: ExecutorQueryInfo): uint64 {.inline.} = info.raw.rowsProcessed()
proc queryId*(info: ExecutorQueryInfo): int64 {.inline.} = info.raw.queryId()
proc hasEstate*(info: ExecutorQueryInfo): bool {.inline.} = info.raw.hasEstate()
