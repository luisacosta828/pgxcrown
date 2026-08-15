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

# Exported PostgreSQL SQL Functions
proc pg_ast_to_raw*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(cstring(sql_text.get), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  return some($astCStr)

proc pg_ast_to_json*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(cstring(sql_text.get), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  let rawAst = $astCStr
  let jsonStr = "{\"status\":\"parsed\",\"raw_sql\":" & escapeJson(sql_text.get) & ",\"ast_tree\":" & escapeJson(rawAst) & "}"
  return some(jsonStr)

proc pg_ast_query_type*(sql_text: string = "SELECT 1"): string =
  if sql_text.strip.len == 0:
    return "UNKNOWN"

  let listPtr = raw_parser(cstring(sql_text), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return "SYNTAX_ERROR"

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return "UNKNOWN"

  let raw = ($astCStr).toUpperAscii()
  if "SELECTSTMT" in raw: return "SELECT"
  elif "INSERTSTMT" in raw: return "INSERT"
  elif "UPDATESTMT" in raw: return "UPDATE"
  elif "DELETESTMT" in raw: return "DELETE"
  elif "DROPSTMT" in raw: return "DROP"
  elif "CREATESTMT" in raw: return "CREATE"
  else: return "OTHER"
