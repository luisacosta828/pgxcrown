import std/[macros, os, strutils, tables]


const entrypoint {.strdefine.} = ""


template NimToSQLType(dt: string): string =
  case dt
  of "int", "int32": "int4"
  of "int64": "int8"
  of "float", "float32": "float4"
  of "float64": "float8"
  of "string": "Text"
  of "cstring": "cstring"
  else: dt

proc project(path: string): string {.inline.} =
  path.splitPath.head.splitPath.head.splitPath.tail

proc buildSQLFunction(fn: NimNode, sql_scripts: var string) =
  var
    returnType = " returns " & NimToSQLType fn.params[0].repr
    paramLen = fn.params.len - 1

  var param_list: seq[string]
  for e in fn.params[1 .. paramLen]:
    param_list.add NimToSQLType e[1].repr

  sql_scripts.add "\nCREATE FUNCTION " & fn.name.repr & '(' & param_list.join(",") & ')' & returnType & " as\n"
  sql_scripts.add "'" & project(entrypoint) & "', 'pgx_" & fn.name.repr & "'\n"
  sql_scripts.add "language c strict;\n"

proc lift_base_datatypes(function: NimNode, custom_datatypes: Table[string, string]) =
  for idx in 0 ..< len(function.params):
    if idx == 0:
      if function.params[0].repr in custom_datatypes:
        function.params[0] = ident(custom_datatypes[function.params[0].repr])
    else:
      if function.params[idx][1].repr in custom_datatypes:
        function.params[idx][1] = ident(custom_datatypes[function.params[idx][1].repr])


template triggered_by_create_type(source) =
  hints["create-type"] = "pgxtool create-type template" in file_content.repr
  
macro decorateMainFunctions*() =
  var file_content = readFile(entrypoint)
  var source = parseStmt(file_content)
  del(source)

  var res = newNimNode(nnkStmtList)
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  res.add ident("PG_MODULE_MAGIC")

  var custom_datatypes: Table[string, string]
  var hints: Table[string, bool]

  triggered_by_create_type(source)

  var v1fns: seq[NimNode]
  var sql_scripts: string
  var (dir, file, _) = splitFile(entrypoint)
  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(ident("pgx"))
  for el in source:
    if el.kind == nnkProcDef:
      el.pragma = pgx_pragma
      v1fns.add ident("pgx_" & el.name.repr)
      buildSQLFunction(el, sql_scripts)
      # Must be one custom datatype per file
      if custom_datatypes.len == 1:
        lift_base_datatypes(el, custom_datatypes)
    elif el.kind == nnkTypeSection and hints["create-type"]:
      var 
        custom_dt = el[0][0].repr
        base_dt   = el[0][2].repr
      custom_datatypes[custom_dt] = base_dt

  writeFile(dir / project(entrypoint) & ".sql", sql_scripts)

  for el in v1fns:
    source.add quote do:
      PG_FUNCTION_INFO_V1(`el.repr`)

  res.add source[0..^1]
  writeFile(entrypoint, res.repr)

decorateMainFunctions()
