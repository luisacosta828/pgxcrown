{.push header: "utils/elog.h".}

var NOTICE {.importc.}: cint    
var INFO {.importc.}: cint
var WARNING {.importc.}: cint    

{.pop.}

proc info*(): cint {.inline.} = INFO

proc notice*(): cint {.inline.} = NOTICE

proc warning*(): cint {.inline.} = WARNING

