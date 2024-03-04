import std/[macros, os]

const entrypoint {. strdefine .} = ""

macro decorateMainFunctions*() =
  echo getProjectPath()
  var source = parseStmt(readFile(entrypoint))
  del(source)

  var res = newNimNode(nnkStmtList)
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  res.add ident("PG_MODULE_MAGIC")

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

  res.add source[0..^1]
  writeFile(entrypoint,res.repr)

decorateMainFunctions()
