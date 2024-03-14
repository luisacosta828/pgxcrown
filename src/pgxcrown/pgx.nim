import std/[macros, os, strutils]

const entrypoint {. strdefine .} = ""

proc NimToSQLType(dt: string): string =
  case dt:
    of "int","int32": "int4"
    of "int64":  "int8"
    of "float", "float32": "float4"
    of "float64": "float64"
    else: "unknown"


proc buildSQLFunction(fn: NimNode, sql_scripts: var string) =
  var 
    returnType = " returns " & NimToSQLType fn.params[0].repr
    paramLen   = fn.params.len - 1

  var param_list: seq[string]
  for e in fn.params[1 .. paramLen]:
    param_list.add NimToSQLType e[1].repr

  var (dir, file, ext) = splitFile(entrypoint)
  sql_scripts.add "\nCREATE FUNCTION " & fn.name.repr & "(" & param_list.join(",") & ")" & returnType & " as\n" 
  sql_scripts.add "'lib" & file & "', 'pgx_" & fn.name.repr & "'\n"
  sql_scripts.add "language c strict;\n"


macro decorateMainFunctions*() =
  echo getProjectPath()
  var source = parseStmt(readFile(entrypoint))
  del(source)

  var res = newNimNode(nnkStmtList)
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  res.add ident("PG_MODULE_MAGIC")

  var v1fns: seq[NimNode]
  var sql_scripts:string
  echo entrypoint
  var (dir, file, ext) = splitFile(entrypoint)
  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(ident("pgx"))
  for el in source:
    if el.kind == nnkProcDef:
      el.pragma = pgx_pragma
      v1fns.add ident("pgx_" & el.name.repr)
      buildSQLFunction(el, sql_scripts)

  writeFile(dir / file & ".sql", sql_scripts)
  for el in v1fns:
    source.add quote do:
      PG_FUNCTION_INFO_V1(`el.repr`)

  res.add source[0..^1]
  writeFile(entrypoint,res.repr)

decorateMainFunctions()
