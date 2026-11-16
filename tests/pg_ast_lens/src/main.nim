import pgxcrown
import std/[options, strutils, json]

# Low-level PostgreSQL internal C header imports (kept private)
{.push header: "parser/parser.h".}
type RawParseMode = cint
const RAW_PARSE_DEFAULT: RawParseMode = 0
proc raw_parser(str: cstring, mode: RawParseMode): pointer {.importc: "raw_parser".}
{.pop.}

{.push header: "nodes/print.h".}
proc nodeToString(obj: pointer): cstring {.importc: "nodeToString".}
{.pop.}

{.emit: """
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
static const char* pgx_ast_stmt_kind(void* listVoid) {
  List* list = (List*)listVoid;
  if (list == NULL || list_length(list) == 0) return "UNKNOWN";
  RawStmt* rs = (RawStmt*)linitial(list);
  if (rs == NULL || rs->stmt == NULL) return "UNKNOWN";
  switch (nodeTag(rs->stmt)) {
    case T_SelectStmt: return "SELECT";
    case T_InsertStmt: return "INSERT";
    case T_UpdateStmt: return "UPDATE";
    case T_DeleteStmt: return "DELETE";
    case T_DropStmt:   return "DROP";
    case T_CreateStmt: return "CREATE";
    default:           return "OTHER";
  }
}
""".}
proc pgx_ast_stmt_kind(listPtr: pointer): cstring {.importc: "pgx_ast_stmt_kind", nodecl.}

# Exported PostgreSQL SQL Functions
proc pg_ast_to_raw*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(($sql_text.get).cstring, RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  return some($astCStr)

proc pg_ast_to_json*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(($sql_text.get).cstring, RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  let rawAst = $astCStr
  let jsonStr = "{\"status\":\"parsed\",\"raw_sql\":" & escapeJson($sql_text.get) & ",\"ast_tree\":" & escapeJson(rawAst) & "}"
  return some(jsonStr)

proc pg_ast_query_type*(sql_text: string = "SELECT 1"): string =
  if sql_text.strip.len == 0:
    return "UNKNOWN"

  let listPtr = raw_parser(($sql_text).cstring, RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return "SYNTAX_ERROR"

  return $pgx_ast_stmt_kind(listPtr)
