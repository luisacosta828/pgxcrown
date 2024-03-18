#{.emit: ["""#include "postgres.h""""] .}
{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}
{. push header: "utils/elog.h" .}

type
  ErrorData* {.importc:  "ErrorData" , incompletestruct .} = ref object
    lineno: int

{.pop.}


