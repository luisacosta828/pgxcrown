## =============================================================================
## Pgxcrown emit_log Hook Types & Safe ErrorData Accessors
## =============================================================================

import ../reports/errcodes

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

{.push header: "utils/elog.h".}

type
  ErrorData* {.importc: "ErrorData", incompletestruct.} = object
    elevel*: cint
    output_to_server*: bool
    output_to_client*: bool
    hide_stmt*: bool
    hide_ctx*: bool
    sqlerrcode*: cint
    message*: cstring
    detail*: cstring
    detail_log*: cstring
    hint*: cstring
    context*: cstring
    schema_name*: cstring
    table_name*: cstring
    column_name*: cstring
    datatype_name*: cstring
    constraint_name*: cstring
    lineno*: cint

  ErrorDataPtr* = ptr ErrorData
  emit_log_hook_type* {.exportc.} = proc(edata: ptr ErrorData) {.cdecl.}

{.pop.}

type
  EmitLogHook* = proc(edata: ptr ErrorData)
  EmitLogCallback* = EmitLogHook

proc errorMessage*(edata: ptr ErrorData): string {.inline.} =
  ## Safely returns the primary error message string from ErrorData (or "" if nil).
  if edata == nil or edata.message == nil: "" else: $edata.message

proc errorDetail*(edata: ptr ErrorData): string {.inline.} =
  ## Safely returns the detail string from ErrorData (or "" if nil).
  if edata == nil or edata.detail == nil: "" else: $edata.detail

proc errorHint*(edata: ptr ErrorData): string {.inline.} =
  ## Safely returns the hint string from ErrorData (or "" if nil).
  if edata == nil or edata.hint == nil: "" else: $edata.hint

proc errorSqlState*(edata: ptr ErrorData): string {.inline.} =
  ## Decodes ErrorData.sqlerrcode into a 5-character SQLSTATE string (or "00000" if nil).
  if edata == nil: "00000" else: unpackSqlState(edata.sqlerrcode)

proc suppressServerLog*(edata: ptr ErrorData) {.inline.} =
  ## Suppresses emission of this log record to the PostgreSQL server log.
  if edata != nil:
    edata.output_to_server = false

proc suppressClientLog*(edata: ptr ErrorData) {.inline.} =
  ## Suppresses emission of this log record to the client.
  if edata != nil:
    edata.output_to_client = false
