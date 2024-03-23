#{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#""".}

{. push header: "utils/elog.h" .}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

type
  ErrorData* {.importc:  "ErrorData" , incompletestruct .} = object
    elevel: cint
    output_to_server: bool
    output_to_client: bool
    hide_stmt: bool
    hide_ctx: bool
    message: cstring
    detail: cstring
    detail_log: cstring
    hint: cstring
    context: cstring
    schema_name: cstring
    table_name: cstring
    column_name: cstring
    datatype_name: cstring
    constraint_name: cstring
    lineno: cint

  emit_log_hook_type* {.exportc.} = proc(edata: ptr ErrorData) {. cdecl .}

{.pop.}
