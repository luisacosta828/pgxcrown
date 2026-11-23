import pgxcrown/compiler
import pgxcrown/datatypes/basic
import pgxcrown/datatypes/heaptuples
import pgxcrown/datatypes/arrays
import pgxcrown/datatypes/jsonb
import pgxcrown/datatypes/strings
import pgxcrown/datatypes/bytea
import pgxcrown/datatypes/uuid
import pgxcrown/datatypes/temporal
import pgxcrown/datatypes/numeric
include pgxcrown/pgxmacros
import pgxcrown/reports/reports
import pgxcrown/query_builder
import pgxcrown/spi
import pgxcrown/bgworker
import pgxcrown/native_functions
import pgxcrown/allocator
import pgxcrown/memcontext
import pgxcrown/lwlock
import pgxcrown/shmem
import pgxcrown/shm_mq
import pgxcrown/guc

template trusted*() {.pragma: [raises: [ValueError], forbids: [IOEffect, TimeEffect], tags: []].}
template immutable*() {.pragma: [noSideEffect, trusted, forbids: [DbReadEffect, DbWriteEffect]].}
template stable*() {.pragma: [trusted, forbids: [DbWriteEffect]].}
template volatile*() {.pragma: [trusted].}
template parallelSafe*() {.pragma: [trusted].}
template parallelRestricted*() {.pragma: [trusted].}
template calledOnNullInput*() {.pragma.}

# Declarative Custom Base Type Pragmas
template pgxType*(baseType: typed) {.pragma.}
template pgxInput*() {.pragma.}
template pgxInput*(customType: typed) {.pragma.}
template pgxOutput*() {.pragma.}
template pgxOutput*(customType: typed) {.pragma.}
template pgxReceive*() {.pragma.}
template pgxReceive*(customType: typed) {.pragma.}
template pgxSend*() {.pragma.}
template pgxSend*(customType: typed) {.pragma.}

# Function Volatility, Security & Extension Metadata Pragmas
template securityDefiner*() {.pragma.}
template securityInvoker*() {.pragma.}
template leakproof*() {.pragma.}
template searchPath*(path: string) {.pragma.}
macro pgxExtension*(args: varargs[untyped]): untyped = newStmtList()

# Background Worker & Hook Pragmas
template pgxWorker*() {.pragma.}
template pgxWorker*(name: string) {.pragma.}
template pgxInit*() {.pragma.}
template pgxShmem*() {.pragma.}
template noSql*() {.pragma.}
template pgxPreload*() {.pragma.}

const pgTargetVersion* {.intdefine.}: int = 0

template PGX_SUBMODULE_HEADERS*() =
  const DLL* = "PGDLLEXPORT $# $#$#"
  const V1_DEF* = "PGDLLEXPORT $# $#(PG_FUNCTION_ARGS)"
  {.pragma: pgdllexport, codegenDecl: DLL, exportc.}
  {.pragma: pgv1 , codegenDecl: V1_DEF, exportc, dynlib.}
  {.pragma: pgv1_plnim , codegenDecl: "PGDLLEXPORT $# $#$#", exportc, dynlib.}
  {.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
""".}

template PG_MODULE_MAGIC*() =
  PGX_SUBMODULE_HEADERS()
  {.emit: """PG_MODULE_MAGIC;""".}


template PG_FUNCTION_INFO_V1*(funcname: typed) =
  {.emit: ["""PG_FUNCTION_INFO_V1(""", funcname.astToStr, """);"""] .}


template ActivateHooks*() =
  {.pragma: user_hook, codegenDecl: "static $1 $2", exportc.}
  {.pragma: original_hook, codegenDecl: "$1 $2", exportc, nodecl.}
  {.pragma: pginitexport, codegenDecl: "PGDLLEXPORT $# _PG_init(void)", exportc.}

  {.emit: """/*INCLUDESECTION*/
    #include "postgres.h"
    #include "fmgr.h"
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((weak)) int pgx_force_libc_alloc = 0;
    __attribute__((constructor(101))) static void pgx_hook_pre_nim_init(void) {
      pgx_force_libc_alloc++;
    }
    static void pgx_hook_post_nim_init(void) {
      if (pgx_force_libc_alloc > 0) {
        pgx_force_libc_alloc--;
      }
    }
#else
    static void pgx_hook_post_nim_init(void) {}
#endif
  """.}
  proc pgxHookPostNimInit() {.importc: "pgx_hook_post_nim_init", nodecl.}
  pgxHookPostNimInit()

proc toParam*(v: PgText): QueryParam {.inline.} = toParam(toString(v))
proc toColumnExpr*(v: PgText): ColumnExpr {.inline.} =
  ColumnExpr(expr: quoteLiteral(toString(v)), alias: "")
converter toQueryParam*(v: PgText): QueryParam = toParam(toString(v))
proc desc*(d: Datum): string {.error: "Raw PostgreSQL Datum cannot be used with .desc; pass a ColumnRef, SqlIdent, or column name string.".}
proc asc*(d: Datum): string {.error: "Raw PostgreSQL Datum cannot be used with .asc; pass a ColumnRef, SqlIdent, or column name string.".}
when (NimMajor, NimMinor) >= (2, 2):
  {.push warning[InvalidCmpOp]: off.}
proc `==`*(c: ColumnRef, val: PgText): SqlExpr {.inline.} = c == toParam(val)
proc `!=`*(c: ColumnRef, val: PgText): SqlExpr {.inline.} = c != toParam(val)
proc `==`*(c: ColumnExpr, val: PgText): SqlExpr {.inline.} = c == toParam(val)
proc `!=`*(c: ColumnExpr, val: PgText): SqlExpr {.inline.} = c != toParam(val)
when (NimMajor, NimMinor) >= (2, 2):
  {.pop.}
proc Set*(step: UpdateStep or UpdateSetStep, col: ColumnRef, val: PgText): UpdateSetStep {.inline.} =
  Set(step, col, toParam(val))
proc toParam*[T](v: PgVector[T]): QueryParam {.inline.} = toParam(@v)
converter toQueryParam*[T](v: PgVector[T]): QueryParam = toParam(v)
proc toParam*(v: PgBytea): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgBytea): QueryParam = toParam($v)
proc toParam*(v: PgUuid): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgUuid): QueryParam = toParam($v)
proc toParam*(v: PgDate): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgDate): QueryParam = toParam($v)
proc toParam*(v: PgTimestamp): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgTimestamp): QueryParam = toParam($v)
proc toParam*(v: PgTimestampTz): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgTimestampTz): QueryParam = toParam($v)
proc toParam*(v: PgInterval): QueryParam {.inline.} = toParam($v)
converter toQueryParam*(v: PgInterval): QueryParam = toParam($v)
proc toParam*(v: PgNumeric): QueryParam {.inline.} =
  QueryParam(kind: pkRaw, rawVal: quoteLiteral($v) & "::numeric")
converter toQueryParam*(v: PgNumeric): QueryParam = toParam(v)


export compiler
export basic
export reports
export heaptuples
export arrays
export jsonb
export bytea
export uuid
export temporal
export numeric
export query_builder
export spi
export strings
export bgworker
export native_functions
export allocator
export memcontext
export lwlock
export shmem
export shm_mq
export guc

