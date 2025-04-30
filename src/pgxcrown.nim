import pgxcrown/compiler
import pgxcrown/datatypes/basic
#import pgxcrown/utils
include pgxcrown/pgxmacros

template PG_MODULE_MAGIC*() =
  const DLL* = "PGDLLEXPORT $# $#$#"
  const V1_DEF* = "PGDLLEXPORT $# $#(PG_FUNCTION_ARGS)"
  {.pragma: pgdllexport, codegenDecl: DLL, exportc.}
  {.pragma: pgv1 , codegenDecl: V1_DEF, exportc, dynlib.}
  {.pragma: pgv1_plnim , codegenDecl: "PGDLLEXPORT $# $#$#", exportc, dynlib.}
  {.pragma: trusted, raises: [ValueError], forbids: [], tags: [].}
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

export compiler
export basic
