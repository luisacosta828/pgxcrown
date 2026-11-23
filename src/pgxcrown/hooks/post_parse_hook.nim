## =============================================================================
## Pgxcrown post_parse_analyze Hook Types & Safe Parse/Query Accessors
## =============================================================================

import std/os

const
  PgxPostParseCHeadersDir = currentSourcePath.parentDir.parentDir / "c_headers"
  pgHookTargetVersion {.intdefine: "pgTargetVersion".}: int = 0

{.passC: "-I" & quoteShell(PgxPostParseCHeadersDir).}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "parser/analyze.h"
""".}

proc detectHookPgMajor(): int {.compileTime.} =
  when pgHookTargetVersion > 0:
    return pgHookTargetVersion
  else:
    let (outStr, code) = gorgeEx("pg_config --version")
    if code == 0:
      var num = 0
      var inNum = false
      for ch in outStr:
        if ch >= '0' and ch <= '9':
          inNum = true
          num = num * 10 + (ord(ch) - ord('0'))
        elif inNum:
          break
      if num > 0:
        return num
    return 15

const effectiveHookPgMajor = detectHookPgMajor()

when effectiveHookPgMajor > 0 and effectiveHookPgMajor < 15:
  type
    CmdType* {.size: sizeof(cint).} = enum
      CMD_UNKNOWN = 0
      CMD_SELECT = 1
      CMD_UPDATE = 2
      CMD_INSERT = 3
      CMD_DELETE = 4
      CMD_UTILITY = 5
      CMD_NOTHING = 6
else:
  type
    CmdType* {.size: sizeof(cint).} = enum
      CMD_UNKNOWN = 0
      CMD_SELECT = 1
      CMD_UPDATE = 2
      CMD_INSERT = 3
      CMD_DELETE = 4
      CMD_MERGE = 5
      CMD_UTILITY = 6
      CMD_NOTHING = 7

{.push header: "parser/analyze.h".}

type
  ParseState* {.importc: "ParseState", incompletestruct.} = object
  Query* {.importc: "Query", incompletestruct.} = object
    commandType*: CmdType
  JumbleState* {.importc: "JumbleState", incompletestruct.} = object
  JumbleStatePtr* = ptr JumbleState

  post_parse_analyze_hook_type* {.exportc.} = proc(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr) {.cdecl.}

{.pop.}

type
  PostParseHook* = proc(pstate: ptr ParseState, query: ptr Query, jstate: JumbleStatePtr)
  PostParseCallback* = PostParseHook

{.push header: "pgx_hooks.h".}
proc pgxPstateSourceText(pstate: ptr ParseState): cstring {.importc: "pgx_pstate_source_text".}
proc pgxQueryId(query: ptr Query): int64 {.importc: "pgx_query_id".}
{.pop.}

proc sourceText*(pstate: ptr ParseState): string {.inline.} =
  ## Safely extracts ParseState.p_sourcetext (returns "" if nil).
  if pstate == nil:
    return ""
  let s = pgxPstateSourceText(pstate)
  if s == nil: "" else: $s

proc queryId*(query: ptr Query): int64 {.inline.} =
  ## Safely extracts Query.queryId across PG 14-18 (returns 0 if nil).
  pgxQueryId(query)
