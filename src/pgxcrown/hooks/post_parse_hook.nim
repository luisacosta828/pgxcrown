{.push header: "parser/analyze.h".}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

type
  CmdType* = enum
    CMD_UNKNOWN
    CMD_SELECT
    CMD_UPDATE
    CMD_INSERT
    CMD_DELETE
    CMD_MERGE
    CMD_UTILITY
    CMD_NOTHING

  ParseState*  {.importc: "ParseState", incompletestruct.}  = object
  Query*       {.importc: "Query", incompletestruct.}       = object
    commandType*: CmdType
  JumbleState* {.importc: "JumbleState", incompletestruct.} = object


  post_parse_analyze_hook_type* {.exportc.} = proc(pstate: ptr ParseState, query: ptr Query, jstate: ptr JumbleState) {. cdecl .}


{. pop .}
