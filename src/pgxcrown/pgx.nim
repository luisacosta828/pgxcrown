import std/[macros, os, strutils, tables]


const entrypoint {.strdefine.} = ""
var recordType {.compileTime.}: seq[string] = @[]

template NimToSQLType(dt: string): string =
  case dt
  of "int", "int32": "int4"
  of "int64": "int8"
  of "int16": "int2"
  of "float", "float32": "float4"
  of "float64": "float8"
  of "string": "Text"
  of "cstring": "cstring"
  of "bool": "boolean"
  else: dt

proc project(path: string): string {.inline.} =
  var p = path.parentDir
  if p.lastPathPart == "src":
    p = p.parentDir
  return p.lastPathPart

proc buildSQLFunction(fn: NimNode, sql_scripts: var string) =
  var
    returnTypeStr = ""
    hasOptionOrDefault = false

  if fn.params[0].kind != nnkEmpty:
    let retTypeNode = fn.params[0]
    if retTypeNode.kind == nnkBracketExpr and retTypeNode[0].repr == "Option":
      returnTypeStr = " returns " & NimToSQLType(retTypeNode[1].repr)
      hasOptionOrDefault = true
    else:
      returnTypeStr = " returns " & NimToSQLType(retTypeNode.repr)

  var paramLen = fn.params.len - 1
  var procTy = if returnTypeStr == "": "PROCEDURE " else: "FUNCTION "
  
  var param_list: seq[string]
  for i in 1 .. paramLen:
    let identDef = fn.params[i]
    let paramTypeNode = identDef[^2]
    let defaultNode = identDef[^1]
    
    let isOptionParam = paramTypeNode.kind == nnkBracketExpr and paramTypeNode[0].repr == "Option"
    var baseTypeStr = ""
    if isOptionParam:
      baseTypeStr = NimToSQLType(paramTypeNode[1].repr)
      hasOptionOrDefault = true
    elif paramTypeNode.kind == nnkIdent and paramTypeNode.repr notin recordType:
      baseTypeStr = NimToSQLType(paramTypeNode.repr)
    elif paramTypeNode.kind == nnkTupleConstr or paramTypeNode.repr in recordType:
      baseTypeStr = "record"
    else:
      baseTypeStr = paramTypeNode.repr

    if defaultNode.kind != nnkEmpty:
      hasOptionOrDefault = true

    let nameCount = identDef.len - 2
    for j in 0 ..< nameCount:
      var entry = baseTypeStr
      if defaultNode.kind != nnkEmpty:
        entry.add " DEFAULT "
        case defaultNode.kind
        of nnkStrLit, nnkTripleStrLit:
          entry.add "'" & defaultNode.strVal & "'"
        of nnkIntLit, nnkInt32Lit, nnkInt64Lit, nnkFloatLit, nnkFloat64Lit:
          entry.add defaultNode.repr
        of nnkIdent:
          if defaultNode.repr in ["true", "false"]:
            entry.add defaultNode.repr
          elif defaultNode.repr in ["nil", "none"]:
            entry.add "NULL"
          else:
            entry.add defaultNode.repr
        of nnkCall:
          if defaultNode[0].repr == "none":
            entry.add "NULL"
          elif defaultNode[0].repr == "some":
            if defaultNode[1].kind in {nnkStrLit, nnkTripleStrLit}:
              entry.add "'" & defaultNode[1].strVal & "'"
            else:
              entry.add defaultNode[1].repr
          else:
            entry.add defaultNode.repr
        else:
          entry.add defaultNode.repr
      elif isOptionParam:
        entry.add " DEFAULT NULL"
      param_list.add entry

  var strict = if returnTypeStr == "": "language c;\n" 
               elif hasOptionOrDefault: "language c;\n" 
               else: "language c strict;\n"

  sql_scripts.add "\nCREATE OR REPLACE " & procTy & fn.name.repr & '(' & param_list.join(", ") & ')' & returnTypeStr & " as\n"
  sql_scripts.add "'" & project(entrypoint) & "', 'pgx_" & fn.name.repr & "'\n"
  sql_scripts.add strict


proc buildEnumType(element: NimNode, sql_scripts: var string) =
  var 
    enum_template = "\nCREATE TYPE $ENUM_NAME AS ENUM ($ENUM_LIST);\n"
    enum_name     = element[0].repr
    enum_list: seq[string] = @[]

  for el in element[2]:
    if el.kind == nnkIdent:
      enum_list.add "'" & el.repr & "'"
  
  sql_scripts.add enum_template.replace("$ENUM_NAME", enum_name).replace("$ENUM_LIST", enum_list.join(","))


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

template check_type_section(element):string =
  case element[2].kind:
  of nnkIdent:  "plain"
  of nnkEnumTy: "enum"
  of nnkObjectTy: "object"
  of nnkTupleConstr: "tupleConstr"
  else: element.treerepr

template addEnumDefaultCase(element) =
  element[2].add ident("PgxUnknownValue")
  
macro decorateMainFunctions*() =
  var file_content = readFile(entrypoint)
  var source = parseStmt(file_content)
  if source.len > 0 and source[0].kind in {nnkImportStmt, nnkImportExceptStmt}:
    source.del(0)

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
    elif el.kind == nnkTypeSection:
      for e in el:
        var pragmaexpr = newNimNode(nnkPragmaExpr)
        var type_checked = check_type_section(e)
        case type_checked:
        of "enum":
          addEnumDefaultCase(e)
          buildEnumType(e, sql_scripts)
          pragmaexpr.add(e[0])
          pragmaexpr.add(pgx_pragma)
          e[0] = pragmaexpr
        of "tupleConstr": 
          recordType.add e[0].repr
          pragmaexpr.add(e[0])
          pragmaexpr.add(pgx_pragma)
          e[0] = pragmaexpr
        of "object":
          recordType.add e[0].repr
          pragmaexpr.add(e[0])
          pragmaexpr.add(pgx_pragma)
          e[0] = pragmaexpr
        else:
          discard


  let prjName = project(entrypoint)
  let controlContent = "# " & prjName & " extension\ncomment = '" & prjName & " extension for PostgreSQL'\ndefault_version = '0.0.1'\nmodule_pathname = '$libdir/" & prjName & "'\nrelocatable = true\n"
  writeFile(dir / prjName & ".control", controlContent)
  writeFile(dir / prjName & ".sql", sql_scripts)
  writeFile(dir / prjName & "--0.0.1.sql", sql_scripts)

  for el in v1fns:
    source.add quote do:
      PG_FUNCTION_INFO_V1(`el.repr`)

  res.add source[0..^1]
  writeFile(entrypoint, res.repr)

decorateMainFunctions()
