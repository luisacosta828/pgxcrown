import std/[macros, os, strutils, tables, json]
import compiler, spi, query_builder
export json, spi, query_builder, compiler

const entrypoint {.strdefine.} = ""
var recordType {.compileTime.}: seq[string] = @[]

proc NimToSQLType(dt: string): string =
  let cleanDt = dt.strip(chars = {'*'})
  case cleanDt
  of "int", "int32": "int4"
  of "int64": "int8"
  of "int16": "int2"
  of "float", "float32": "float4"
  of "float64": "float8"
  of "string": "Text"
  of "cstring": "cstring"
  of "char": "char"
  of "uint", "uint32": "oid"
  of "bool", "boolean": "boolean"
  of "JsonNode", "Json", "json": "jsonb"
  of "Jsonb", "jsonb": "jsonb"
  of "seq[int]", "seq[int32]": "int4[]"
  of "seq[int64]": "int8[]"
  of "seq[float]", "seq[float32]": "float4[]"
  of "seq[float64]": "float8[]"
  of "seq[string]": "text[]"
  of "seq[bool]": "bool[]"
  of "seq[JsonNode]", "seq[Jsonb]", "seq[jsonb]": "jsonb[]"
  else:
    if cleanDt.startsWith("seq["):
      let inner = cleanDt[4 .. ^2].strip(chars = {'*'})
      let sqlInner = if inner in recordType: "\"" & inner & "\"" else: NimToSQLType(inner)
      let finalSqlInner = if sqlInner.endsWith("[]"): sqlInner else: sqlInner & "[]"
      finalSqlInner
    elif cleanDt in recordType:
      "\"" & cleanDt & "\""
    else:
      "record"

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
    elif retTypeNode.kind == nnkBracketExpr and retTypeNode[0].repr == "seq":
      let innerType = retTypeNode[1].repr.strip(chars = {'*'})
      let sqlInner = if innerType in recordType: "\"" & innerType & "\"" else: NimToSQLType(innerType)
      let finalSqlInner = if sqlInner.endsWith("[]"): sqlInner[0 .. ^3] else: sqlInner
      returnTypeStr = " returns SETOF " & finalSqlInner
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
    let isSeqParam = paramTypeNode.kind == nnkBracketExpr and paramTypeNode[0].repr == "seq"
    var baseTypeStr = ""
    if isOptionParam:
      baseTypeStr = NimToSQLType(paramTypeNode[1].repr)
      hasOptionOrDefault = true
    elif isSeqParam:
      baseTypeStr = NimToSQLType(paramTypeNode.repr)
    else:
      baseTypeStr = NimToSQLType(paramTypeNode.repr)

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
        of nnkPrefix:
          if defaultNode[0].repr == "%*":
            entry.add "'" & defaultNode.repr[2 .. ^1] & "'"
          else:
            entry.add defaultNode.repr
        else:
          if baseTypeStr in ["json", "jsonb"] and defaultNode.repr.startsWith("%*"):
            entry.add "'" & defaultNode.repr[2 .. ^1] & "'"
          else:
            entry.add defaultNode.repr
      elif isOptionParam:
        entry.add " DEFAULT NULL"
      param_list.add entry

  var volatility = ""
  var parallel = ""
  var isStrict = not hasOptionOrDefault

  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pRepr = p.repr.toLowerAscii
      if pRepr in ["immutable"]:
        volatility = " IMMUTABLE"
      elif pRepr in ["stable"]:
        volatility = " STABLE"
      elif pRepr in ["volatile"]:
        volatility = " VOLATILE"
      elif pRepr in ["parallelsafe", "parallel_safe"]:
        parallel = " PARALLEL SAFE"
      elif pRepr in ["parallelrestricted", "parallel_restricted"]:
        parallel = " PARALLEL RESTRICTED"
      elif pRepr in ["calledonnullinput", "called_on_null_input"]:
        isStrict = false
      elif pRepr in ["strict"]:
        isStrict = true

  var strictStr = if isStrict and returnTypeStr != "": " STRICT" else: ""
  var optionsStr = "language c" & volatility & parallel & strictStr & ";\n"

  var fnNameStr = fn.name.repr.strip(chars = {'*'})
  sql_scripts.add "\nCREATE OR REPLACE " & procTy & fnNameStr & '(' & param_list.join(", ") & ')' & returnTypeStr & " as\n"
  sql_scripts.add "'" & project(entrypoint) & "', 'pgx_" & fnNameStr & "'\n"
  sql_scripts.add optionsStr


proc buildEnumType(element: NimNode, sql_scripts: var string) =
  var 
    enum_template = "\nCREATE TYPE \"$ENUM_NAME\" AS ENUM ($ENUM_LIST);\n"
    enum_name     = element[0].repr.strip(chars = {'*'})
    enum_list: seq[string] = @[]

  for el in element[2]:
    if el.kind == nnkIdent:
      enum_list.add "'" & el.repr & "'"
  
  sql_scripts.add enum_template.replace("$ENUM_NAME", enum_name).replace("$ENUM_LIST", enum_list.join(","))

proc buildObjectType(element: NimNode, sql_scripts: var string) =
  var objName = element[0].repr.strip(chars = {'*'})
  var fields: seq[string] = @[]
  
  if element[2].kind == nnkObjectTy and element[2].len >= 3:
    let recList = element[2][2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldTypeStr = NimToSQLType(identDef[^2].repr)
          for fieldNameNode in identDef[0 .. ^3]:
            let fieldNameStr = fieldNameNode.repr.strip(chars = {'*'})
            fields.add "\"" & fieldNameStr & "\" " & fieldTypeStr

  if fields.len > 0:
    let typeSql = "\nCREATE TYPE \"" & objName & "\" AS (\n  " & fields.join(",\n  ") & "\n);\n"
    sql_scripts.add typeSql

proc lift_base_datatypes(function: NimNode, custom_datatypes: Table[string, string]) =
  for idx in 0 ..< len(function.params):
    if idx == 0:
      if function.params[0].repr in custom_datatypes:
        function.params[0] = ident(custom_datatypes[function.params[0].repr])
    else:
      if function.params[idx][1].repr in custom_datatypes:
        function.params[idx][1] = ident(custom_datatypes[function.params[idx][1].repr])


template triggered_by_create_type(source) =
  hints["create-type"] = "pgxtool create-type template" in source.repr

template check_type_section(element):string =
  case element[2].kind:
  of nnkIdent:  "plain"
  of nnkEnumTy: "enum"
  of nnkObjectTy: "object"
  of nnkTupleConstr: "tupleConstr"
  else: element.treerepr

template addEnumDefaultCase(element) =
  element[2].add ident("PgxUnknownValue")
  
proc isImportc(fn: NimNode): bool =
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      if p.kind == nnkIdent and p.repr == "importc":
        return true
      elif p.kind == nnkExprColonExpr and p[0].repr == "importc":
        return true
  return false

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

  # Pass 1: Process type definitions first so recordType is populated and types are emitted
  for el in source:
    if el.kind == nnkTypeSection and hints["create-type"]:
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
          recordType.add e[0].repr.strip(chars = {'*'})
          pragmaexpr.add(e[0])
          pragmaexpr.add(pgx_pragma)
          e[0] = pragmaexpr
        of "object":
          let cleanName = e[0].repr.strip(chars = {'*'})
          recordType.add cleanName
          buildObjectType(e, sql_scripts)
          pragmaexpr.add(e[0])
          pragmaexpr.add(pgx_pragma)
          e[0] = pragmaexpr
        else:
          discard

  # Pass 2: Process function definitions
  for el in source:
    if el.kind in {nnkProcDef, nnkFuncDef}:
      if not isImportc(el):
        var fnNameStr = el.name.repr.strip(chars = {'*'})
        v1fns.add ident("pgx_" & fnNameStr)
        buildSQLFunction(el, sql_scripts)
        if el.pragma.kind == nnkEmpty:
          el.pragma = newNimNode(nnkPragma)
        el.pragma.add(ident("pgx"))
        if custom_datatypes.len == 1:
          lift_base_datatypes(el, custom_datatypes)

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
