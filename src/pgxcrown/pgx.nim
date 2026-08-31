import std/[macros, os, strutils, tables, json, options]
export json, tables
import ../pgxcrown
export pgxcrown

const entrypoint {.strdefine.} = ""
var recordType {.compileTime.}: seq[string] = @[]

type
  BaseTypeInfo = object
    name: string
    baseType: string
    sqlBaseType: string
    inputFn: string
    outputFn: string
    receiveFn: string
    sendFn: string

proc NimToSQLType(dt: string): string =
  let cleanDt = dt.strip(chars = {'*'})
  case cleanDt
  of "int", "int32": "int4"
  of "int64": "int8"
  of "int16": "int2"
  of "int8": "char"
  of "uint", "uint32": "oid"
  of "uint16": "int2"
  of "uint64": "int8"
  of "uint8": "char"
  of "float", "float32": "float4"
  of "float64": "float8"
  of "string": "Text"
  of "cstring": "cstring"
  of "char": "char"
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
      let sqlInner = if inner in recordType: inner else: NimToSQLType(inner)
      let finalSqlInner = if sqlInner.endsWith("[]"): sqlInner else: sqlInner & "[]"
      finalSqlInner
    elif cleanDt in recordType:
      cleanDt
    else:
      "record"

proc project(path: string): string {.inline.} =
  var p = path.parentDir
  if p.lastPathPart == "src":
    p = p.parentDir
  return p.lastPathPart

proc extractBaseType(typedefNode: NimNode): Option[BaseTypeInfo] =
  if typedefNode.kind == nnkTypeDef:
    let nameNode = typedefNode[0]
    var typeName = ""
    var baseType = ""
    
    if nameNode.kind == nnkPragmaExpr and nameNode.len >= 2:
      typeName = nameNode[0].repr.strip(chars = {'*'})
      let pragmaNode = nameNode[1]
      for p in pragmaNode:
        if p.kind == nnkExprColonExpr and p[0].repr.toLowerAscii in ["pgxtype", "pgx_type"]:
          baseType = p[1].repr.strip(chars = {'*'})
        elif p.kind == nnkIdent and p.repr.toLowerAscii in ["pgxtype", "pgx_type"]:
          if typedefNode[2].kind == nnkDistinctTy:
            baseType = typedefNode[2][0].repr.strip(chars = {'*'})
          else:
            baseType = typedefNode[2].repr.strip(chars = {'*'})
    elif typedefNode[2].kind == nnkDistinctTy:
      typeName = nameNode.repr.strip(chars = {'*'})
      baseType = typedefNode[2][0].repr.strip(chars = {'*'})
    
    if typeName.len > 0 and baseType.len > 0:
      return some(BaseTypeInfo(name: typeName, baseType: baseType, sqlBaseType: NimToSQLType(baseType)))
  return none(BaseTypeInfo)

proc getFnRole(fn: NimNode): (string, string) =
  ## Returns (role: "input"|"output"|"receive"|"send"|"", targetType: string)
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pName = if p.kind == nnkExprColonExpr: p[0].repr.toLowerAscii else: p.repr.toLowerAscii
      let pArg = if p.kind == nnkExprColonExpr: p[1].repr.strip(chars = {'*'}) else: ""
      if pName in ["pgxinput", "pgx_input"]:
        return ("input", pArg)
      elif pName in ["pgxoutput", "pgx_output"]:
        return ("output", pArg)
      elif pName in ["pgxreceive", "pgx_receive"]:
        return ("receive", pArg)
      elif pName in ["pgxsend", "pgx_send"]:
        return ("send", pArg)
  return ("", "")

proc buildBaseTypeFunctionSQL(fn: NimNode, role: string, targetType: string, sql_scripts: var string) =
  let fnNameStr = fn.name.repr.strip(chars = {'*'})
  var paramsStr = ""
  var returnTypeStr = ""
  
  case role
  of "input":
    paramsStr = "cstring"
    returnTypeStr = targetType
  of "output":
    paramsStr = targetType
    returnTypeStr = "cstring"
  of "receive":
    paramsStr = "internal"
    returnTypeStr = targetType
  of "send":
    paramsStr = targetType
    returnTypeStr = "bytea"
  else:
    discard

  sql_scripts.add "\nCREATE OR REPLACE FUNCTION " & fnNameStr & "(" & paramsStr & ") returns " & returnTypeStr & " as\n"
  sql_scripts.add "'" & project(entrypoint) & "', 'pgx_" & fnNameStr & "'\n"
  sql_scripts.add "language c IMMUTABLE PARALLEL SAFE STRICT;\n"

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
      let sqlInner = if innerType in recordType: innerType else: NimToSQLType(innerType)
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
    enum_template = "\nCREATE TYPE $ENUM_NAME AS ENUM ($ENUM_LIST);\n"
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
    let typeSql = "\nCREATE TYPE " & objName & " AS (\n  " & fields.join(",\n  ") & "\n);\n"
    sql_scripts.add typeSql

proc lift_base_datatypes(function: NimNode, custom_datatypes: Table[string, string]) =
  for idx in 0 ..< len(function.params):
    if idx == 0:
      let retRepr = function.params[0].repr.strip(chars = {'*'})
      if retRepr in custom_datatypes:
        function.params[0] = newIdentNode(custom_datatypes[retRepr])
    else:
      let paramRepr = function.params[idx][1].repr.strip(chars = {'*'})
      if paramRepr in custom_datatypes:
        function.params[idx][1] = newIdentNode(custom_datatypes[paramRepr])

template check_type_section(element):string =
  case element[2].kind:
  of nnkIdent:  "plain"
  of nnkEnumTy: "enum"
  of nnkObjectTy: "object"
  of nnkTupleConstr: "tupleConstr"
  else: element.treerepr

template addEnumDefaultCase(element) =
  element[2].add newIdentNode("PgxUnknownValue")
  
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
  res.add newNimNode(nnkImportStmt).add newIdentNode("pgxcrown")
  res.add newIdentNode("PG_MODULE_MAGIC")

  var baseTypes: Table[string, BaseTypeInfo]
  var custom_datatypes: Table[string, string]

  var sql_shell_types = ""
  var sql_enums = ""
  var sql_objects = ""
  var sql_base_type_fns = ""
  var sql_base_type_ddls = ""
  var sql_functions = ""

  var v1fns: seq[NimNode]
  var (dir, file, _) = splitFile(entrypoint)
  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(newIdentNode("pgx"))

  # Pass 1: Process type definitions
  for el in source:
    if el.kind == nnkTypeSection:
      for e in el:
        let baseOpt = extractBaseType(e)
        if baseOpt.isSome:
          let info = baseOpt.get
          baseTypes[info.name] = info
          custom_datatypes[info.name] = info.baseType
          recordType.add info.name
          sql_shell_types.add "\nCREATE TYPE " & info.name & ";\n"
        else:
          var pragmaexpr = newNimNode(nnkPragmaExpr)
          var type_checked = check_type_section(e)
          case type_checked:
          of "enum":
            let cleanName = e[0].repr.strip(chars = {'*'})
            recordType.add cleanName
            addEnumDefaultCase(e)
            buildEnumType(e, sql_enums)
            pragmaexpr.add(e[0])
            pragmaexpr.add(pgx_pragma)
            e[0] = pragmaexpr
          of "tupleConstr": 
            pragmaexpr.add(e[0])
            pragmaexpr.add(pgx_pragma)
            e[0] = pragmaexpr
          of "object":
            let cleanName = e[0].repr.strip(chars = {'*'})
            recordType.add cleanName
            buildObjectType(e, sql_objects)
            pragmaexpr.add(e[0])
            pragmaexpr.add(pgx_pragma)
            e[0] = pragmaexpr
          else:
            discard

  proc isExportedProc(fn: NimNode): bool =
    if fn.len > 0:
      if fn[0].kind == nnkPostfix:
        return true
      if "*" in fn[0].repr:
        return true
    return false

  # Pass 2: Process function definitions
  for el in source:
    if el.kind in {nnkProcDef, nnkFuncDef}:
      let (role, declaredTargetType) = getFnRole(el)
      let isExp = isExportedProc(el) or role.len > 0
      if not isImportc(el) and isExp:
        var fnNameStr = el.name.repr.strip(chars = {'*'})
        v1fns.add newIdentNode("pgx_" & fnNameStr)

        let (role, declaredTargetType) = getFnRole(el)
        if role.len > 0:
          var targetType = declaredTargetType
          if targetType.len == 0:
            if role in ["input", "receive"]:
              targetType = el.params[0].repr.strip(chars = {'*'})
            elif role in ["output", "send"] and el.params.len > 1:
              targetType = el.params[1][^2].repr.strip(chars = {'*'})
          
          if targetType in baseTypes:
            var info = baseTypes[targetType]
            case role
            of "input": info.inputFn = fnNameStr
            of "output":
              info.outputFn = fnNameStr
              el.params[0] = newIdentNode("cstring")
            of "receive": info.receiveFn = fnNameStr
            of "send": info.sendFn = fnNameStr
            else: discard
            baseTypes[targetType] = info

            buildBaseTypeFunctionSQL(el, role, targetType, sql_base_type_fns)
          else:
            buildSQLFunction(el, sql_functions)
        else:
          buildSQLFunction(el, sql_functions)

        if custom_datatypes.len > 0:
          lift_base_datatypes(el, custom_datatypes)

        if el.pragma.kind == nnkEmpty:
          el.pragma = newNimNode(nnkPragma)
        el.pragma.add(newIdentNode("pgx"))

  # Pass 3: Finalize Base Type DDLs
  for typeName, info in baseTypes:
    if info.inputFn.len > 0 and info.outputFn.len > 0:
      var ddl = "\nCREATE TYPE " & info.name & " (\n"
      ddl.add "  INPUT = " & info.inputFn & ",\n"
      ddl.add "  OUTPUT = " & info.outputFn
      if info.receiveFn.len > 0:
        ddl.add ",\n  RECEIVE = " & info.receiveFn
      if info.sendFn.len > 0:
        ddl.add ",\n  SEND = " & info.sendFn
      ddl.add ",\n  LIKE = " & info.sqlBaseType & "\n);\n"
      sql_base_type_ddls.add ddl

  var sql_scripts = ""
  sql_scripts.add sql_shell_types
  sql_scripts.add sql_base_type_fns
  sql_scripts.add sql_base_type_ddls
  sql_scripts.add sql_enums
  sql_scripts.add sql_objects
  sql_scripts.add sql_functions

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
