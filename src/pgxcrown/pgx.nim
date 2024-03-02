import pgxmacros
import std/[macros, os]

const entrypoint {. strdefine .} = ""

macro decorateMainFunctions(): untyped =
  var source = parseStmt(readFile(entrypoint))
  del(source)
  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(ident("pgx"))
  for el in source:
    if el.kind == nnkProcDef:
      el.pragma = pgx_pragma

  result = source



decorateMainFunctions()
