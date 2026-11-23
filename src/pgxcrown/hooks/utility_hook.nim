## =============================================================================
## Pgxcrown ProcessUtility Hook Types & PlannedStmt/DropStmt Accessors (PG 14-18)
## =============================================================================

import std/[os, strutils]
import ../allocator

const PgxUtilHookCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
{.passC: "-I" & quoteShell(PgxUtilHookCHeadersDir).}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "tcop/utility.h"
#include "pgx_hooks.h"
""".}

type
  PlannedStmtObj* {.importc: "PlannedStmt", header: "nodes/plannodes.h", incompleteStruct.} = object
  PlannedStmtPtr* = ptr PlannedStmtObj

  ProcessUtilityContext* {.size: sizeof(cint).} = enum
    PROCESS_UTILITY_TOPLEVEL        = 0
    PROCESS_UTILITY_QUERY           = 1
    PROCESS_UTILITY_QUERY_NONATOMIC = 2
    PROCESS_UTILITY_SUBCOMMAND      = 3

  ProcessUtility_hook_type* {.importc: "ProcessUtility_hook_type", header: "tcop/utility.h".} = proc(
    pstmt: PlannedStmtPtr,
    queryString: cstring,
    readOnlyTree: bool,
    context: ProcessUtilityContext,
    params: pointer,
    queryEnv: pointer,
    dest: pointer,
    qc: pointer
  ) {.cdecl.}

  UtilityStmtInfo* = object
    ## Lightweight POD handle passed to composable ProcessUtility callbacks
    rawPstmt*: PlannedStmtPtr
    queryStringPtr*: cstring
    readOnlyTree*: bool
    context*: ProcessUtilityContext
    params*: pointer
    queryEnv*: pointer
    dest*: pointer
    qc*: pointer

  ProcessUtilityHook* = proc(info: UtilityStmtInfo)
  ProcessUtilityCallback* = ProcessUtilityHook

{.push header: "pgx_hooks.h".}
proc pgxUtilityNodeTag(pstmt: PlannedStmtPtr): int32 {.importc: "pgx_utility_node_tag".}
proc pgxUtilityTagName(pstmt: PlannedStmtPtr): cstring {.importc: "pgx_utility_tag_name".}
proc pgxUtilityIsDropStmt(pstmt: PlannedStmtPtr): bool {.importc: "pgx_utility_is_drop_stmt".}
proc pgxUtilityDropRemoveType(pstmt: PlannedStmtPtr): int32 {.importc: "pgx_utility_drop_remove_type".}
proc pgxUtilityIsDropTable(pstmt: PlannedStmtPtr): bool {.importc: "pgx_utility_is_drop_table".}
proc pgxUtilityDropTargetsCsv(pstmt: PlannedStmtPtr): cstring {.importc: "pgx_utility_drop_targets_csv".}
{.pop.}

proc queryString*(info: UtilityStmtInfo): string {.inline.} =
  ## Safely returns the utility SQL query string (or "" if nil).
  if info.queryStringPtr == nil: "" else: $info.queryStringPtr

proc nodeTag*(pstmt: PlannedStmtPtr): int32 {.inline.} =
  ## Safely returns NodeTag of PlannedStmt->utilityStmt (0 / T_Invalid if NULL).
  pgxUtilityNodeTag(pstmt)

proc tagName*(pstmt: PlannedStmtPtr): string {.inline.} =
  ## Safely returns canonical node tag name (e.g., "DropStmt", "CreateStmt", "None").
  let s = pgxUtilityTagName(pstmt)
  if s == nil: "None" else: $s

proc isDropStmt*(pstmt: PlannedStmtPtr): bool {.inline.} =
  ## Returns true when PlannedStmt->utilityStmt is a DropStmt.
  pgxUtilityIsDropStmt(pstmt)

proc dropRemoveType*(pstmt: PlannedStmtPtr): int32 {.inline.} =
  ## Returns DropStmt->removeType (or -1 if not a DropStmt).
  pgxUtilityDropRemoveType(pstmt)

proc isDropTable*(pstmt: PlannedStmtPtr): bool {.inline.} =
  ## Returns true when PlannedStmt->utilityStmt is a DROP TABLE statement.
  pgxUtilityIsDropTable(pstmt)

proc dropTargetsCsv*(pstmt: PlannedStmtPtr): string =
  ## Formats DropStmt->objects as a comma-separated string across PG 14-18.
  let raw = pgxUtilityDropTargetsCsv(pstmt)
  if raw == nil:
    return ""
  result = $raw
  pfree(cast[pointer](raw))

proc dropTargets*(pstmt: PlannedStmtPtr): seq[string] =
  ## Returns individual object names targeted by a DropStmt.
  let csv = pstmt.dropTargetsCsv()
  if csv.len == 0:
    return @[]
  result = csv.split(',')

proc dropTargetsContain*(pstmt: PlannedStmtPtr, target: string): bool =
  ## Checks whether `target` matches any object in DropStmt (exact or unqualified tail).
  let needle = target.strip().toLowerAscii()
  if needle.len == 0:
    return false
  for entry in pstmt.dropTargets():
    let lower = entry.toLowerAscii()
    if lower == needle:
      return true
    if '.' notin needle:
      let dotPos = lower.rfind('.')
      if dotPos >= 0 and lower[dotPos + 1 .. ^1] == needle:
        return true
  return false

proc nodeTag*(info: UtilityStmtInfo): int32 {.inline.} = info.rawPstmt.nodeTag()
proc tagName*(info: UtilityStmtInfo): string {.inline.} = info.rawPstmt.tagName()
proc isDropStmt*(info: UtilityStmtInfo): bool {.inline.} = info.rawPstmt.isDropStmt()
proc dropRemoveType*(info: UtilityStmtInfo): int32 {.inline.} = info.rawPstmt.dropRemoveType()
proc isDropTable*(info: UtilityStmtInfo): bool {.inline.} = info.rawPstmt.isDropTable()
proc dropTargetsCsv*(info: UtilityStmtInfo): string {.inline.} = info.rawPstmt.dropTargetsCsv()
proc dropTargets*(info: UtilityStmtInfo): seq[string] {.inline.} = info.rawPstmt.dropTargets()
proc dropTargetsContain*(info: UtilityStmtInfo, target: string): bool {.inline.} =
  info.rawPstmt.dropTargetsContain(target)
