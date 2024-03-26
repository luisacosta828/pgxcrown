{.push header: "parser/analyze.h".}

type
  ParseState*  {.importc: "ParseState", incompletestruct.}  = object
  Query*       {.importc: "Query", incompletestruct.}       = object
  JumbleState* {.importc: "JumbleState", incompletestruct.} = object


  post_parse_analyze_hook_type* {.exportc.} = proc(pstate: ptr ParseState, query: ptr Query, jstate: ptr JumbleState) {. cdecl .}


{. pop .}
