import std/[macros, os]

const entrypoint {. strdefine .} = ""

macro decorateMainFunctions*() =
  var source = parseStmt(readFile(entrypoint))
  del(source)

  result = newNimNode(nnkStmtList)
  result.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  result.add ident("PG_MODULE_MAGIC")

  var v1fns: seq[NimNode]
  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(ident("pgx"))
  for el in source:
    if el.kind == nnkProcDef:
      el.pragma = pgx_pragma
      v1fns.add ident("pgx_" & el.name.repr)

  for el in v1fns:
    source.add quote do:
      PG_FUNCTION_INFO_V1(`el.repr`)

  result.add source[0..^1]
  writeFile(entrypoint,result.repr)

decorateMainFunctions()
