include pgxcrown/utils
include pgxcrown/pgxmacros

template PG_MODULE_MAGIC*() =
  const DLL* = "PGDLLEXPORT $# $#$#"
  const V1_DEF* = "PGDLLEXPORT $# $#(PG_FUNCTION_ARGS)"
  {.pragma: pgdllexport, codegenDecl: DLL, exportc.}
  {.pragma: pgv1 , codegenDecl: V1_DEF, exportc, dynlib.}
  {.emit: """PG_MODULE_MAGIC;""" .}


template PG_FUNCTION_INFO_V1*(funcname: typed) =
  {.emit: ["""PG_FUNCTION_INFO_V1(""", funcname.astToStr, """);"""] .}


template ActivateHooks*() =
  {.pragma: user_hook, codegenDecl: "static $1 $2", exportc.}
  {.pragma: original_hook, codegenDecl: "$1 $2", exportc, nodecl.}
  {.pragma: pginitexport, codegenDecl: "PGDLLEXPORT $# _PG_init(void)", exportc.}

  {.emit: """/*INCLUDESECTION*/
    #include "postgres.h"
    #include "fmgr.h"
  """.}

