import std/[macros, os, strutils, tables, json, options, sets, hashes]
export json, tables
import ../pgxcrown
export pgxcrown
import ./ext_meta
export ext_meta

const entrypoint* {.strdefine.} = ""
const pgxProjectDir* {.strdefine.} = ""
const pgxRealOutDir* {.strdefine.} = ""

var recordType {.compileTime.}: seq[string] = @[]
var plainDistinctTypes {.compileTime.} = initTable[string, string]()
var enumValueMap {.compileTime.} = initTable[string, string]()

type
  BaseTypeInfo = object
    name: string
    baseType: string
    sqlBaseType: string
    inputFn: string
    outputFn: string
    receiveFn: string
    sendFn: string

  LocalModuleInfo = object
    path: string
    modId: string
    ast: NimNode
    isMain: bool
    importAnchors: seq[tuple[anchorIdent: string, alias: string]]
    v1Fns: seq[NimNode]

  ParsedFnMeta = object
    fnName: string
    sqlParams: seq[string]
    normParamKeys: seq[string]
    sigKey: string
    cSym: string
    role: string
    targetType: string
    isOverloaded: bool

proc NimToSQLType(dt: string): string =
  let cleanDt = dt.strip(chars = {'*'}).strip()
  case cleanDt
  of "int", "int32": "int4"
  of "int64": "int8"
  of "int16": "int2"
  of "int8": "\"char\""
  of "uint", "uint32": "oid"
  of "uint16": "int2"
  of "uint64": "int8"
  of "uint8": "\"char\""
  of "float", "float32": "float4"
  of "float64": "float8"
  of "string", "PgText": "Text"
  of "cstring": "cstring"
  of "char": "\"char\""
  of "bool", "boolean": "boolean"
  of "PgBytea": "bytea"
  of "PgUuid": "uuid"
  of "PgDate": "date"
  of "PgTimestamp": "timestamp"
  of "PgTimestampTz": "timestamptz"
  of "PgInterval": "interval"
  of "PgNumeric": "numeric"
  of "JsonNode", "Json", "json": "jsonb"
  of "Jsonb", "jsonb": "jsonb"
  of "seq[int]", "seq[int32]": "int4[]"
  of "seq[int64]": "int8[]"
  of "seq[float]", "seq[float32]": "float4[]"
  of "seq[float64]": "float8[]"
  of "seq[string]", "seq[PgText]": "text[]"
  of "seq[bool]": "bool[]"
  of "seq[PgBytea]": "bytea[]"
  of "seq[PgUuid]": "uuid[]"
  of "seq[PgDate]": "date[]"
  of "seq[PgTimestamp]": "timestamp[]"
  of "seq[PgTimestampTz]": "timestamptz[]"
  of "seq[PgInterval]": "interval[]"
  of "seq[PgNumeric]": "numeric[]"
  of "seq[JsonNode]", "seq[Jsonb]", "seq[jsonb]": "jsonb[]"
  of "PgVector[int32]", "PgVector[int]": "int4[]"
  of "PgVector[int64]": "int8[]"
  of "PgVector[int16]": "int2[]"
  of "PgVector[float32]", "PgVector[float]": "float4[]"
  of "PgVector[float64]": "float8[]"
  of "PgVector[bool]": "bool[]"
  else:
    if cleanDt.startsWith("Option[") and cleanDt.endsWith("]"):
      NimToSQLType(cleanDt[7 .. ^2])
    elif cleanDt.startsWith("seq["):
      let inner = cleanDt[4 .. ^2].strip(chars = {'*'})
      let sqlInner = if inner in recordType: "\"" & inner & "\"" else: NimToSQLType(inner)
      let finalSqlInner = if sqlInner.endsWith("[]"): sqlInner else: sqlInner & "[]"
      finalSqlInner
    elif cleanDt in plainDistinctTypes:
      NimToSQLType(plainDistinctTypes[cleanDt])
    elif cleanDt in recordType:
      "\"" & cleanDt & "\""
    else:
      "record"

proc resolveEffectiveProjectDir(ep: string): string =
  if pgxProjectDir.len > 0:
    return pgxProjectDir
  var p = ep.parentDir
  if p.lastPathPart == "src":
    p = p.parentDir
  return p

proc resolveRealOutDir(ep: string): string =
  if pgxRealOutDir.len > 0:
    return pgxRealOutDir
  return ep.parentDir

proc projectNameFromPaths(ep, projDir: string): string =
  let tail = projDir.splitPath.tail
  if tail.len > 0:
    return tail
  var p = ep.parentDir
  if p.lastPathPart == "src":
    p = p.parentDir
  p.lastPathPart

proc extractTypeName(nameNode: NimNode): string =
  if nameNode.kind == nnkPragmaExpr and nameNode.len >= 1:
    return extractTypeName(nameNode[0])
  return nameNode.repr.strip(chars = {'*'}).strip()

proc isTypeExported(nameNode: NimNode): bool =
  if nameNode.kind == nnkPostfix:
    return true
  if nameNode.kind == nnkPragmaExpr and nameNode.len >= 1:
    return isTypeExported(nameNode[0])
  "*" in nameNode.repr

proc hasTypePragma(typeDef: NimNode, names: openArray[string]): bool =
  if typeDef.kind != nnkTypeDef or typeDef.len < 1:
    return false
  let nameNode = typeDef[0]
  if nameNode.kind == nnkPragmaExpr and nameNode.len >= 2 and nameNode[1].kind == nnkPragma:
    for p in nameNode[1]:
      let pName = (if p.kind == nnkExprColonExpr: p[0].repr else: p.repr).toLowerAscii
      if pName in names:
        return true
  return false

proc attachTypePragma(typeDef: NimNode, pragmaNode: NimNode) =
  if typeDef[0].kind == nnkPragmaExpr and typeDef[0].len >= 2 and typeDef[0][1].kind == nnkPragma:
    for p in pragmaNode:
      typeDef[0][1].add p.copyNimTree()
  else:
    var pragmaexpr = newNimNode(nnkPragmaExpr)
    pragmaexpr.add(typeDef[0])
    pragmaexpr.add(pragmaNode)
    typeDef[0] = pragmaexpr

proc hasProcPragma(pragmas: NimNode, targetName: string): bool =
  if pragmas.kind == nnkPragma:
    let wanted = targetName.toLowerAscii
    for p in pragmas:
      let pName = (if p.kind == nnkExprColonExpr: p[0].repr else: p.repr).toLowerAscii
      if pName == wanted:
        return true
  return false

proc extractBaseType(typedefNode: NimNode): Option[BaseTypeInfo] =
  if typedefNode.kind == nnkTypeDef:
    let nameNode = typedefNode[0]
    var typeName = ""
    var baseType = ""

    if nameNode.kind == nnkPragmaExpr and nameNode.len >= 2:
      typeName = extractTypeName(nameNode)
      let pragmaNode = nameNode[1]
      for p in pragmaNode:
        if p.kind == nnkExprColonExpr and p[0].repr.toLowerAscii in ["pgxtype", "pgx_type"]:
          baseType = p[1].repr.strip(chars = {'*'})
        elif p.kind == nnkIdent and p.repr.toLowerAscii in ["pgxtype", "pgx_type"]:
          if typedefNode[2].kind == nnkDistinctTy:
            baseType = typedefNode[2][0].repr.strip(chars = {'*'})
          else:
            baseType = typedefNode[2].repr.strip(chars = {'*'})

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

proc isImportc(fn: NimNode): bool =
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      if p.kind == nnkIdent and p.repr == "importc":
        return true
      elif p.kind == nnkExprColonExpr and p[0].repr == "importc":
        return true
  return false

proc isExportedProc(fn: NimNode): bool =
  if fn.len > 0:
    if fn[0].kind == nnkPostfix:
      return true
    if "*" in fn[0].repr:
      return true
  return false

proc isWorkerProc(fn: NimNode): bool =
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pName = if p.kind == nnkExprColonExpr: p[0].repr.toLowerAscii else: p.repr.toLowerAscii
      if pName in ["pgxworker", "pgx_worker", "bgworker"]:
        return true
  return false

proc isInitProc(fn: NimNode): bool =
  let fnNameStr = fn.name.repr.strip(chars = {'*'})
  if fnNameStr == "_PG_init":
    return true
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pName = if p.kind == nnkExprColonExpr: p[0].repr.toLowerAscii else: p.repr.toLowerAscii
      if pName in ["pgxinit", "pgx_init"]:
        return true
  return false

proc isGenericRoutine(fn: NimNode): bool =
  fn.len > 2 and fn[2].kind != nnkEmpty

proc isNoSqlRoutine(fn: NimNode): bool =
  hasProcPragma(fn.pragma, "nosql") or hasProcPragma(fn.pragma, "no_sql")

proc injectStackDepthGuard(fn: NimNode) =
  ## Injects `checkStackDepth()` at the entry of pure-Nim helpers so deep recursion raises SQLSTATE 54001.
  if fn.kind notin {nnkProcDef, nnkFuncDef} or fn.body.kind == nnkEmpty:
    return
  if isImportc(fn) or hasProcPragma(fn.pragma, "cdecl") or
     hasProcPragma(fn.pragma, "exportc") or hasProcPragma(fn.pragma, "inline"):
    return
  let guardCall = newCall(newIdentNode("checkStackDepth"))
  if fn.body.kind == nnkStmtList:
    var insertIdx = 0
    while insertIdx < fn.body.len and fn.body[insertIdx].kind == nnkCommentStmt:
      inc insertIdx
    fn.body.insert(insertIdx, guardCall)
  else:
    fn.body = newStmtList(guardCall, fn.body)

# -----------------------------------------------------------------------------
# Local Multi-Module Import Graph & Include Splicing
# -----------------------------------------------------------------------------
proc flattenImportExpr(n: NimNode): seq[tuple[spec: string, alias: string]] =
  result = @[]
  case n.kind
  of nnkIdent, nnkSym:
    result = @[(spec: n.repr.strip(), alias: "")]
  of nnkStrLit, nnkTripleStrLit:
    result = @[(spec: n.strVal, alias: "")]
  of nnkPrefix:
    if n.len >= 2:
      let pfx = n[0].repr.strip()
      for sub in flattenImportExpr(n[1]):
        let sep = if pfx.endsWith("/"): "" else: "/"
        result.add((spec: pfx & sep & sub.spec, alias: sub.alias))
  of nnkInfix:
    let op = n[0].repr.strip()
    if op == "as" and n.len >= 3:
      let aliasName = n[2].repr.strip()
      for sub in flattenImportExpr(n[1]):
        result.add((spec: sub.spec, alias: aliasName))
    elif op == "/" and n.len >= 3:
      let lefts = flattenImportExpr(n[1])
      let rights = flattenImportExpr(n[2])
      for l in lefts:
        for r in rights:
          result.add((spec: l.spec & "/" & r.spec, alias: r.alias))
  of nnkBracket:
    for child in n:
      for sub in flattenImportExpr(child):
        result.add(sub)
  of nnkPar:
    if n.len == 1:
      return flattenImportExpr(n[0])
  else:
    discard

proc isLocalImportAliasable(stmtKind: NimNodeKind): bool =
  stmtKind in {nnkImportStmt, nnkImportExceptStmt}

proc resolveLocalNimFile(spec: string, curDir, srcRoot: string): string =
  if spec.len == 0:
    return ""
  if spec == "pgxcrown" or spec.startsWith("pgxcrown/") or spec.startsWith("std/"):
    return ""
  let cleanSpec = if spec.endsWith(".nim"): spec else: spec & ".nim"
  var candidates: seq[string] = @[normalizedPath(curDir / cleanSpec)]
  if not cleanSpec.startsWith("./") and not cleanSpec.startsWith("../") and not isAbsolute(cleanSpec):
    candidates.add(normalizedPath(srcRoot / cleanSpec))

  let normSrc = normalizedPath(srcRoot)
  let normPrefix = normSrc & "/"
  for cand in candidates:
    if fileExists(cand) and (cand == normSrc or cand.startsWith(normPrefix)):
      return cand
  ""

proc expandIncludesInAst(stmtList: NimNode, curDir, srcRoot: string,
                         incStack: var seq[string]): NimNode =
  result = newNimNode(stmtList.kind)
  for node in stmtList:
    if node.kind == nnkIncludeStmt:
      var replacedAny = false
      var keptUnresolved: seq[NimNode] = @[]
      for ch in node:
        let specs = flattenImportExpr(ch)
        if specs.len == 1:
          let incPath = resolveLocalNimFile(specs[0].spec, curDir, srcRoot)
          if incPath.len > 0:
            if incPath in incStack:
              error("Circular local include detected: " & incPath, node)
            incStack.add(incPath)
            let incAst = parseStmt(readFile(incPath))
            let expandedInc = expandIncludesInAst(incAst, incPath.parentDir, srcRoot, incStack)
            discard incStack.pop()
            for s in expandedInc:
              result.add(s)
            replacedAny = true
            continue
        keptUnresolved.add(ch)
      if not replacedAny or keptUnresolved.len > 0:
        if keptUnresolved.len == node.len:
          result.add(node)
        elif keptUnresolved.len > 0:
          let newInc = newNimNode(nnkIncludeStmt)
          for u in keptUnresolved:
            newInc.add(u)
          result.add(newInc)
    else:
      result.add(node)

proc moduleIdForPath(modPath, stagedRoot: string): string =
  var rel = modPath
  let rootPrefix = normalizedPath(stagedRoot) & "/"
  if modPath.startsWith(rootPrefix):
    rel = modPath[rootPrefix.len .. ^1]
  if rel.endsWith(".nim"):
    rel = rel[0 .. ^5]
  var clean = ""
  for ch in rel:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}:
      clean.add(ch)
    elif clean.len == 0 or clean[^1] != '_':
      clean.add('_')
  clean = clean.strip(chars = {'_'})
  if clean.len == 0:
    clean = "mod"
  let h = toHex(abs(hash(modPath)), 6).toLowerAscii()
  "pgx_" & clean & "_" & h

proc collectLocalModules(
  modPath: string,
  isMain: bool,
  srcRoot, stagedRoot: string,
  visiting: var HashSet[string],
  visitTrail: var seq[string],
  visited: var HashSet[string],
  ordered: var seq[LocalModuleInfo]
) =
  let normPath = normalizedPath(modPath)
  if normPath in visiting:
    error("Circular local module import detected: " & visitTrail.join(" -> ") & " -> " & normPath)
  if normPath in visited:
    return

  visiting.incl(normPath)
  visitTrail.add(normPath)

  var incStack: seq[string] = @[normPath]
  let rawAst = parseStmt(readFile(normPath))
  let ast = expandIncludesInAst(rawAst, normPath.parentDir, srcRoot, incStack)

  var anchors: seq[tuple[anchorIdent: string, alias: string]] = @[]
  var seenAnchors = initHashSet[string]()
  for stmt in ast:
    if stmt.kind in {nnkImportStmt, nnkImportExceptStmt, nnkFromStmt}:
      let items =
        if stmt.kind == nnkImportStmt: stmt[0 .. ^1]
        elif stmt.len > 0: @[stmt[0]]
        else: @[]
      for ch in items:
        for pair in flattenImportExpr(ch):
          let depPath = resolveLocalNimFile(pair.spec, normPath.parentDir, srcRoot)
          if depPath.len > 0:
            collectLocalModules(depPath, isMain = false, srcRoot, stagedRoot, visiting, visitTrail, visited, ordered)
            if isLocalImportAliasable(stmt.kind):
              let depModId = moduleIdForPath(depPath, stagedRoot)
              let anchorIdent = "pgxModAnchor_" & depModId
              let key = anchorIdent & ":" & pair.alias
              if key notin seenAnchors:
                seenAnchors.incl(key)
                anchors.add((anchorIdent: anchorIdent, alias: pair.alias))

  discard visitTrail.pop()
  visiting.excl(normPath)
  visited.incl(normPath)

  ordered.add(LocalModuleInfo(
    path: normPath,
    modId: moduleIdForPath(normPath, stagedRoot),
    ast: ast,
    isMain: isMain,
    importAnchors: anchors,
    v1Fns: @[]
  ))

# -----------------------------------------------------------------------------
# Extension Metadata Parsing from `pgxExtension`
# -----------------------------------------------------------------------------
proc parseStringArrayLit(n: NimNode, fieldName: string): seq[string] =
  result = @[]
  case n.kind
  of nnkBracket:
    for item in n:
      if item.kind in {nnkStrLit, nnkTripleStrLit}:
        let s = item.strVal.strip()
        if s.len > 0: result.add(s)
      else:
        error("pgxExtension field '" & fieldName & "' elements must be string literals", item)
  of nnkPrefix:
    if n.len >= 2 and n[0].repr == "@" and n[1].kind == nnkBracket:
      return parseStringArrayLit(n[1], fieldName)
    error("pgxExtension field '" & fieldName & "' must be a list of strings", n)
  of nnkStrLit, nnkTripleStrLit:
    for p in n.strVal.split(','):
      let s = p.strip()
      if s.len > 0: result.add(s)
  else:
    error("pgxExtension field '" & fieldName & "' must be a string list", n)

proc applyAstExtensionMeta(stmt: NimNode, meta: var ExtensionMeta) =
  proc applyAssign(kv: NimNode, m: var ExtensionMeta) =
    if kv.kind notin {nnkAsgn, nnkExprEqExpr} or kv.len < 2:
      error("pgxExtension expects key = value assignments", kv)
    let k = kv[0].repr.strip().toLowerAscii()
    let val = kv[1]
    case k
    of "version":
      if val.kind notin {nnkStrLit, nnkTripleStrLit}:
        error("pgxExtension version must be a string literal", val)
      m.version = val.strVal.strip()
    of "comment":
      if val.kind notin {nnkStrLit, nnkTripleStrLit}:
        error("pgxExtension comment must be a string literal", val)
      m.comment = val.strVal
    of "relocatable":
      if val.repr in ["true", "false"]:
        m.relocatable = (val.repr == "true")
        m.hasExplicitRelocatable = true
      else:
        error("pgxExtension relocatable must be a bool literal", val)
    of "trusted":
      if val.repr in ["true", "false"]:
        m.trusted = (val.repr == "true")
        m.hasExplicitTrusted = true
      else:
        error("pgxExtension trusted must be a bool literal", val)
    of "schema":
      if val.kind notin {nnkStrLit, nnkTripleStrLit}:
        error("pgxExtension schema must be a string literal", val)
      m.schema = val.strVal.strip()
    of "requires":
      m.requires = parseStringArrayLit(val, "requires")
    else:
      error("Unknown pgxExtension option '" & kv[0].repr & "'", kv)

  for i in 1 ..< stmt.len:
    let arg = stmt[i]
    if arg.kind == nnkStmtList:
      for child in arg:
        if child.kind != nnkCommentStmt:
          applyAssign(child, meta)
    else:
      applyAssign(arg, meta)
  meta.source = "pgxExtension"

# -----------------------------------------------------------------------------
# SQL DDL Builders & Snapshot Collectors
# -----------------------------------------------------------------------------
proc buildBaseTypeFunctionSQL(fn: NimNode, role: string, targetType: string, cSym: string, prjName: string): string =
  let fnNameStr = fn.name.repr.strip(chars = {'*'})
  var paramsStr = ""
  var returnTypeStr = ""
  let quotedTarget = "\"" & targetType & "\""
  case role
  of "input":
    paramsStr = "cstring"
    returnTypeStr = quotedTarget
  of "output":
    paramsStr = quotedTarget
    returnTypeStr = "cstring"
  of "receive":
    paramsStr = "internal"
    returnTypeStr = quotedTarget
  of "send":
    paramsStr = quotedTarget
    returnTypeStr = "bytea"
  else:
    discard

  "\nCREATE OR REPLACE FUNCTION " & fnNameStr & "(" & paramsStr & ") returns " & returnTypeStr & " as\n" &
    "'" & prjName & "', '" & cSym & "'\n" &
    "language c IMMUTABLE PARALLEL SAFE STRICT;\n"

proc extractParamSqlTypes(fn: NimNode): seq[tuple[sqlType: string, isOption: bool, defaultNode: NimNode]] =
  result = @[]
  for i in 1 ..< fn.params.len:
    let identDef = fn.params[i]
    if identDef.kind != nnkIdentDefs or identDef.len < 3:
      continue
    let paramTypeNode = identDef[^2]
    let defaultNode = identDef[^1]
    let isOptionParam = paramTypeNode.kind == nnkBracketExpr and paramTypeNode[0].repr == "Option"
    let baseTypeStr =
      if isOptionParam: NimToSQLType(paramTypeNode[1].repr)
      else: NimToSQLType(paramTypeNode.repr)
    let nameCount = identDef.len - 2
    for j in 0 ..< nameCount:
      result.add((sqlType: baseTypeStr, isOption: isOptionParam, defaultNode: defaultNode))

proc buildSQLFunction(fn: NimNode, cSym: string, prjName: string,
                      routineSnapOut: var RoutineSchema): string =
  var
    returnTypeStr = ""
    hasOptionOrDefault = false
  let isIter = (fn.kind == nnkIteratorDef)
  let rawRetStr =
    if fn.params.len > 0 and fn.params[0].kind != nnkEmpty:
      fn.params[0].repr.strip(chars = {'*'}).strip()
    else:
      ""
  let isVoidReturn = (rawRetStr.len == 0 or rawRetStr.toLowerAscii() == "void")

  if not isVoidReturn:
    let retTypeNode = fn.params[0]
    if isIter:
      let yieldNode =
        if retTypeNode.kind == nnkBracketExpr and retTypeNode[0].repr == "Option": retTypeNode[1]
        else: retTypeNode
      let innerType = yieldNode.repr.strip(chars = {'*'})
      let sqlInner = if innerType in recordType: "\"" & innerType & "\"" else: NimToSQLType(innerType)
      returnTypeStr = " returns SETOF " & sqlInner
    elif retTypeNode.kind == nnkBracketExpr and retTypeNode[0].repr == "Option":
      returnTypeStr = " returns " & NimToSQLType(retTypeNode[1].repr)
      hasOptionOrDefault = true
    elif retTypeNode.kind == nnkBracketExpr and retTypeNode[0].repr == "seq":
      let innerType = retTypeNode[1].repr.strip(chars = {'*'})
      let sqlInner = if innerType in recordType: "\"" & innerType & "\"" else: NimToSQLType(innerType)
      let finalSqlInner = if sqlInner.endsWith("[]"): sqlInner[0 .. ^3] else: sqlInner
      returnTypeStr = " returns SETOF " & finalSqlInner
    else:
      returnTypeStr = " returns " & NimToSQLType(retTypeNode.repr)

  let isProcedure = (not isIter and isVoidReturn)
  let procTy = if isProcedure: "PROCEDURE " else: "FUNCTION "
  let extractedParams = extractParamSqlTypes(fn)

  var paramEntries: seq[tuple[text: string, hasExplicitDefault: bool, isOption: bool]] = @[]
  var sigParamKeys: seq[string] = @[]
  for pe in extractedParams:
    sigParamKeys.add(normalizeSqlTypeKey(pe.sqlType))
    let defaultNode = pe.defaultNode
    if pe.isOption or defaultNode.kind != nnkEmpty:
      hasOptionOrDefault = true
    var entry = pe.sqlType
    if defaultNode.kind != nnkEmpty:
      entry.add " DEFAULT "
      case defaultNode.kind
      of nnkStrLit, nnkTripleStrLit:
        entry.add "'" & defaultNode.strVal.replace("'", "''") & "'"
      of nnkIntLit, nnkInt32Lit, nnkInt64Lit, nnkFloatLit, nnkFloat64Lit:
        entry.add defaultNode.repr
      of nnkIdent:
        if defaultNode.repr in ["true", "false"]:
          entry.add defaultNode.repr
        elif defaultNode.repr in ["nil", "none"]:
          entry.add "NULL"
        elif defaultNode.repr in enumValueMap:
          entry.add "'" & enumValueMap[defaultNode.repr] & "'"
        else:
          entry.add defaultNode.repr
      of nnkDotExpr:
        if defaultNode.repr in enumValueMap:
          entry.add "'" & enumValueMap[defaultNode.repr] & "'"
        else:
          entry.add defaultNode.repr
      of nnkCall:
        if defaultNode[0].repr == "none":
          entry.add "NULL"
        elif defaultNode[0].repr == "some":
          if defaultNode[1].kind in {nnkStrLit, nnkTripleStrLit}:
            entry.add "'" & defaultNode[1].strVal.replace("'", "''") & "'"
          elif defaultNode[1].repr in enumValueMap:
            entry.add "'" & enumValueMap[defaultNode[1].repr] & "'"
          else:
            entry.add defaultNode[1].repr
        elif defaultNode[0].repr in ["pgNumeric", "parsePgUuid", "parsePgDate", "parsePgTimestamp", "parsePgTimestampTz", "parsePgInterval", "fromHexBytea"] and
             defaultNode.len >= 2 and defaultNode[1].kind in {nnkStrLit, nnkTripleStrLit}:
          entry.add "'" & defaultNode[1].strVal.replace("'", "''") & "'"
        elif defaultNode[0].repr in plainDistinctTypes and defaultNode.len >= 2:
          if defaultNode[1].kind in {nnkStrLit, nnkTripleStrLit}:
            entry.add "'" & defaultNode[1].strVal.replace("'", "''") & "'"
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
        if pe.sqlType in ["json", "jsonb"] and defaultNode.repr.startsWith("%*"):
          entry.add "'" & defaultNode.repr[2 .. ^1] & "'"
        else:
          entry.add defaultNode.repr
    paramEntries.add((text: entry, hasExplicitDefault: defaultNode.kind != nnkEmpty, isOption: pe.isOption))

  var suffixHasDefault = true
  for idx in countdown(paramEntries.len - 1, 0):
    if paramEntries[idx].hasExplicitDefault:
      discard
    elif paramEntries[idx].isOption and suffixHasDefault:
      paramEntries[idx].text.add " DEFAULT NULL"
    else:
      suffixHasDefault = false

  var param_list: seq[string] = @[]
  for pe in paramEntries:
    param_list.add pe.text

  var volatility = ""
  var parallel = ""
  var securityClause = ""
  var sawDefiner = false
  var sawInvoker = false
  var sawImmutable = false
  var sawStable = false
  var sawParallel = false
  var sawLeakproof = false
  var sawExplicitStrict = false
  var leakproofClause = ""
  var searchPathClause = ""
  var isStrict = not hasOptionOrDefault

  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pName = (if p.kind == nnkExprColonExpr: p[0].repr else: p.repr).toLowerAscii
      case pName
      of "immutable":
        sawImmutable = true
        volatility = " IMMUTABLE"
      of "stable":
        sawStable = true
        volatility = " STABLE"
      of "volatile":
        if not isProcedure:
          volatility = " VOLATILE"
      of "parallelsafe", "parallel_safe":
        sawParallel = true
        parallel = " PARALLEL SAFE"
      of "parallelrestricted", "parallel_restricted":
        sawParallel = true
        parallel = " PARALLEL RESTRICTED"
      of "calledonnullinput", "called_on_null_input": isStrict = false
      of "strict":
        sawExplicitStrict = true
        isStrict = true
      of "securitydefiner", "security_definer":
        sawDefiner = true
        securityClause = " SECURITY DEFINER"
      of "securityinvoker", "security_invoker":
        sawInvoker = true
        securityClause = " SECURITY INVOKER"
      of "leakproof":
        sawLeakproof = true
        leakproofClause = " LEAKPROOF"
      of "searchpath", "search_path":
        if p.kind != nnkExprColonExpr or p[1].kind notin {nnkStrLit, nnkTripleStrLit}:
          error("searchPath pragma requires a string literal (e.g. {.searchPath: \"public, pg_catalog, pg_temp\".})", p)
        let (spIdents, spErr) = validateSafeIdentList(p[1].strVal, "searchPath")
        if spErr.len > 0:
          error("Invalid searchPath pragma: " & spErr, p)
        searchPathClause = " SET search_path = " & spIdents.join(", ")
      else: discard

  if isProcedure:
    if sawImmutable:
      error("SQL PROCEDURE cannot use {.immutable.}; PostgreSQL rejects volatility attributes on CREATE PROCEDURE", fn)
    if sawStable:
      error("SQL PROCEDURE cannot use {.stable.}; PostgreSQL rejects volatility attributes on CREATE PROCEDURE", fn)
    if sawParallel:
      error("SQL PROCEDURE cannot use parallel safety pragmas ({.parallelSafe.} / {.parallelRestricted.}); PostgreSQL rejects PARALLEL on CREATE PROCEDURE", fn)
    if sawLeakproof:
      error("SQL PROCEDURE cannot use {.leakproof.}; PostgreSQL rejects LEAKPROOF on CREATE PROCEDURE", fn)
    if sawExplicitStrict:
      error("SQL PROCEDURE cannot use {.strict.}; PostgreSQL rejects STRICT on CREATE PROCEDURE", fn)

  if sawDefiner and sawInvoker:
    error("Cannot specify both securityDefiner and securityInvoker on the same SQL routine", fn)

  let strictStr = if isStrict and not isProcedure: " STRICT" else: ""
  let optionsStr = "language c" & volatility & parallel & strictStr & securityClause & leakproofClause & searchPathClause & ";\n"

  let fnNameStr = fn.name.repr.strip(chars = {'*'})
  let ddl = "\nCREATE OR REPLACE " & procTy & fnNameStr & '(' & param_list.join(", ") & ')' & returnTypeStr & " as\n" &
            "'" & prjName & "', '" & cSym & "'\n" &
            optionsStr
  routineSnapOut = RoutineSchema(
    sigKey: fnNameStr & "(" & sigParamKeys.join(",") & ")",
    ddl: ddl.strip()
  )
  ddl

proc buildEnumType(element: NimNode, sql_scripts: var string, enumSnaps: var seq[EnumSchema]) =
  let enum_name = extractTypeName(element[0])
  var enum_list: seq[string] = @[]
  var labels: seq[string] = @[]

  for el in element[2]:
    var identName = ""
    var labelStr = ""
    case el.kind
    of nnkIdent, nnkSym:
      identName = el.repr.strip(chars = {'*'})
      labelStr = identName
    of nnkEnumFieldDef:
      identName = el[0].repr.strip(chars = {'*'})
      if el.len >= 2 and el[1].kind in {nnkStrLit, nnkTripleStrLit}:
        labelStr = el[1].strVal
      elif el.len >= 2 and el[1].kind in {nnkTupleConstr, nnkPar} and el[1].len >= 2 and
           el[1][1].kind in {nnkStrLit, nnkTripleStrLit}:
        labelStr = el[1][1].strVal
      else:
        labelStr = identName
    else:
      discard

    if identName.len > 0:
      let escaped = labelStr.replace("'", "''")
      enum_list.add "'" & escaped & "'"
      labels.add labelStr
      enumValueMap[identName] = escaped
      enumValueMap[enum_name & "." & identName] = escaped

  if enum_list.len > 0:
    sql_scripts.add "\nCREATE TYPE \"" & enum_name & "\" AS ENUM (" & enum_list.join(", ") & ");\n"
    enumSnaps.add EnumSchema(name: enum_name, labels: labels)

proc buildObjectType(element: NimNode, sql_scripts: var string, compSnaps: var seq[CompositeSchema]) =
  let objName = extractTypeName(element[0])
  var fields: seq[string] = @[]
  var compFields: seq[CompositeFieldSchema] = @[]

  if element[2].kind == nnkObjectTy and element[2].len >= 3:
    let recList = element[2][2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldTypeStr = NimToSQLType(identDef[^2].repr)
          for fieldNameNode in identDef[0 .. ^3]:
            let fieldNameStr = fieldNameNode.repr.strip(chars = {'*'})
            fields.add "\"" & fieldNameStr & "\" " & fieldTypeStr
            compFields.add CompositeFieldSchema(name: fieldNameStr, sqlType: fieldTypeStr)

  if fields.len > 0:
    let typeSql = "\nCREATE TYPE \"" & objName & "\" AS (\n  " & fields.join(",\n  ") & "\n);\n"
    sql_scripts.add typeSql
    compSnaps.add CompositeSchema(name: objName, fields: compFields)

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

template check_type_section(element): string =
  case element[2].kind:
  of nnkIdent: "plain"
  of nnkEnumTy: "enum"
  of nnkDistinctTy: "distinct"
  of nnkObjectTy: "object"
  of nnkTupleConstr: "tupleConstr"
  else: element.treerepr

proc buildGuardedInitBody(innerBody: NimNode): NimNode =
  let initScoped = newTree(nnkBlockStmt, newEmptyNode(), innerBody)
  let pendingErrIdent = newIdentNode("pgxPendingErr")
  let errCodeIdent = newIdentNode("pgxErrCode")
  let errMsgIdent = newIdentNode("pgxErrMsg")
  let errDetailIdent = newIdentNode("pgxErrDetail")
  let errHintIdent = newIdentNode("pgxErrHint")
  let eIdent = newIdentNode("e")
  let initImplIdent = newIdentNode("pgxInitGuardedImpl")
  quote do:
    proc `initImplIdent`() =
      var `pendingErrIdent` = false
      var `errCodeIdent`: cint = 0
      var `errMsgIdent`: cstring = nil
      var `errDetailIdent`: cstring = nil
      var `errHintIdent`: cstring = nil
      try:
        pgxWithTopMemoryContext:
          installPgxSharedHooks()
          `initScoped`
      except Defect as `eIdent`:
        prepareNimDefect(`eIdent`, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)
        `pendingErrIdent` = true
      except CatchableError as `eIdent`:
        prepareNimError(`eIdent`, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)
        `pendingErrIdent` = true
      if `pendingErrIdent`:
        pgxEreportFull(ERROR, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)
    pgxRunVoidGuarded(`initImplIdent`)

proc buildGuardedWorkerBody(el: NimNode) =
  if el.pragma.kind == nnkEmpty:
    el.pragma = newNimNode(nnkPragma)
  if not hasProcPragma(el.pragma, "cdecl"):
    el.pragma.add(newIdentNode("cdecl"))
  if not hasProcPragma(el.pragma, "exportc"):
    el.pragma.add(newIdentNode("exportc"))
  if not hasProcPragma(el.pragma, "dynlib"):
    el.pragma.add(newIdentNode("dynlib"))

  var prepends = newTree(nnkStmtList)
  let origParams = el.params
  let origRetType = if origParams.len > 0: origParams[0] else: newEmptyNode()
  var flatParams: seq[(NimNode, NimNode)] = @[]
  for idx in 1 ..< origParams.len:
    let identDef = origParams[idx]
    if identDef.kind == nnkIdentDefs and identDef.len >= 3:
      let pTypeNode = identDef[^2]
      for nameIdx in 0 ..< identDef.len - 2:
        flatParams.add (identDef[nameIdx], pTypeNode)

  el.params = newTree(nnkFormalParams, newEmptyNode(),
    newIdentDefs(newIdentNode("pgx_main_arg"), newIdentNode("Datum")))

  var workerBody: NimNode
  if origRetType.kind != nnkEmpty and flatParams.len == 1:
    let (reqName, reqTypeNode) = flatParams[0]
    let rpcHandlerIdent = newIdentNode("pgxRpcHandler")
    let userRpcBody = el.body
    let handlerProc = newProc(
      name = rpcHandlerIdent,
      params = [origRetType, newIdentDefs(reqName, reqTypeNode)],
      body = userRpcBody
    )
    handlerProc.pragma = newTree(nnkPragma, newIdentNode("nimcall"))
    workerBody = newStmtList(
      handlerProc,
      newCall(
        newTree(nnkBracketExpr, newIdentNode("serveWorkerChannel"),
            reqTypeNode, origRetType),
        rpcHandlerIdent
      )
    )
  else:
    if flatParams.len == 1:
      let (pName, pTypeNode) = flatParams[0]
      let pType = pTypeNode.repr.strip
      if pType == "string":
        prepends.add newLetStmt(pName, newCall(newIdentNode("getWorkerExtra")))
      elif pType == "cstring":
        prepends.add newLetStmt(pName, newCall(newIdentNode("cstring"), newCall(newIdentNode("getWorkerExtra"))))
      elif pType == "Datum":
        prepends.add newLetStmt(pName, newIdentNode("pgx_main_arg"))
      else:
        prepends.add newLetStmt(pName, newTree(nnkCast, pTypeNode, newIdentNode("pgx_main_arg")))
    elif flatParams.len >= 2:
      let (p1Name, p1TypeNode) = flatParams[0]
      let p1Type = p1TypeNode.repr.strip
      let (p2Name, p2TypeNode) = flatParams[1]
      let p2Type = p2TypeNode.repr.strip
      if p1Type == "Datum":
        prepends.add newLetStmt(p1Name, newIdentNode("pgx_main_arg"))
      else:
        prepends.add newLetStmt(p1Name, newTree(nnkCast, p1TypeNode, newIdentNode("pgx_main_arg")))
      if p2Type == "cstring":
        prepends.add newLetStmt(p2Name, newCall(newIdentNode("cstring"), newCall(newIdentNode("getWorkerExtra"))))
      else:
        prepends.add newLetStmt(p2Name, newCall(newIdentNode("getWorkerExtra")))

    workerBody = el.body
    if prepends.len > 0:
      prepends.add workerBody
      workerBody = prepends

  let workerScoped = newTree(nnkBlockStmt, newEmptyNode(), workerBody)
  let pendingExitIdent = newIdentNode("pgxWorkerPendingExit")
  let eIdent = newIdentNode("e")
  el.body = quote do:
    var `pendingExitIdent` = false
    try:
      `workerScoped`
    except CatchableError as `eIdent`:
      pgWarning("Background Worker error: " & `eIdent`.msg)
      `pendingExitIdent` = true
    except Defect as `eIdent`:
      pgWarning("Background Worker defect: " & `eIdent`.msg)
      `pendingExitIdent` = true
    if `pendingExitIdent`:
      workerExit(1)

proc isPgxTopImport(stmt: NimNode): bool =
  if stmt.kind == nnkImportStmt:
    for ch in stmt:
      let r = ch.repr.strip()
      if r in ["pgxcrown", "pgxcrown/pgx"]:
        return true
  false

proc stripPgxTopImport(stmt: NimNode): NimNode =
  if stmt.kind != nnkImportStmt:
    return stmt
  var kept: seq[NimNode] = @[]
  for ch in stmt:
    let r = ch.repr.strip()
    if r notin ["pgxcrown", "pgxcrown/pgx"]:
      kept.add(ch)
  if kept.len == 0:
    return newEmptyNode()
  result = newNimNode(nnkImportStmt)
  for k in kept:
    result.add(k)

macro decorateMainFunctions*() =
  let ep = normalizedPath(entrypoint)
  let projectDir = resolveEffectiveProjectDir(ep)
  let realOutDir = resolveRealOutDir(ep)
  let prjName = projectNameFromPaths(ep, projectDir)
  let srcRoot = ep.parentDir
  let stagedRoot =
    if srcRoot.lastPathPart == "src": srcRoot.parentDir
    else: srcRoot

  var visiting = initHashSet[string]()
  var visitTrail: seq[string] = @[]
  var visited = initHashSet[string]()
  var orderedModules: seq[LocalModuleInfo] = @[]
  collectLocalModules(ep, isMain = true, srcRoot, stagedRoot,
                      visiting, visitTrail, visited, orderedModules)

  var meta = initDefaultExtensionMeta(prjName)
  discard applyNimbleMeta(projectDir, meta)
  discard applyPgxExtJson(projectDir, meta)

  var baseTypes = initTable[string, BaseTypeInfo]()
  var custom_datatypes = initTable[string, string]()
  var sql_shell_types = ""
  var sql_enums = ""
  var sql_objects = ""
  var sql_base_type_fns = ""
  var sql_base_type_ddls = ""
  var sql_functions = ""

  var enumSnaps: seq[EnumSchema] = @[]
  var compSnaps: seq[CompositeSchema] = @[]
  var baseSnaps: seq[BaseTypeSchema] = @[]
  var routineSnaps: seq[RoutineSchema] = @[]

  let pgx_pragma = newNimNode(nnkPragma)
  pgx_pragma.add(newIdentNode("pgx"))

  var hasPgxSharedVars = false

  # Pass 1 (all modules in topological order): Types, {.pgxShared.} vars, pgxExtension
  for modIdx in 0 ..< orderedModules.len:
    let ast = orderedModules[modIdx].ast
    for el in ast:
      if el.kind == nnkCall and el.len >= 1 and el[0].repr.toLowerAscii() == "pgxextension":
        applyAstExtensionMeta(el, meta)
      elif el.kind == nnkVarSection:
        for idDef in el:
          if idDef.kind == nnkIdentDefs and idDef.len >= 3 and idDef[0].kind == nnkPragmaExpr:
            let pNode = idDef[0][1]
            if hasProcPragma(pNode, "pgxshared") or hasProcPragma(pNode, "pgx_shared"):
              hasPgxSharedVars = true
      elif el.kind == nnkTypeSection:
        for e in el:
          if e.kind != nnkTypeDef:
            continue
          let baseOpt = extractBaseType(e)
          if baseOpt.isSome:
            let info = baseOpt.get
            baseTypes[info.name] = info
            if e[2].kind == nnkDistinctTy:
              attachTypePragma(e, pgx_pragma)
            else:
              custom_datatypes[info.name] = info.baseType
            recordType.add info.name
            sql_shell_types.add "\nCREATE TYPE \"" & info.name & "\";\n"
          else:
            if hasTypePragma(e, ["pgxshmem", "pgxshared", "pgx_shared", "nosql", "no_sql", "bycopy", "packed", "importc"]):
              continue
            if not isTypeExported(e[0]):
              continue
            let type_checked = check_type_section(e)
            case type_checked:
            of "enum":
              let cleanName = extractTypeName(e[0])
              recordType.add cleanName
              buildEnumType(e, sql_enums, enumSnaps)
              attachTypePragma(e, pgx_pragma)
            of "distinct":
              let cleanName = extractTypeName(e[0])
              plainDistinctTypes[cleanName] = e[2][0].repr.strip(chars = {'*'}).strip()
              attachTypePragma(e, pgx_pragma)
            of "tupleConstr":
              attachTypePragma(e, pgx_pragma)
            of "object":
              let cleanName = extractTypeName(e[0])
              recordType.add cleanName
              buildObjectType(e, sql_objects, compSnaps)
              attachTypePragma(e, pgx_pragma)
            else:
              discard

  let metaErr = finalizeAndValidateMeta(meta)
  if metaErr.len > 0:
    error("❌ " & metaErr)

  # Pre-pass 2a: Collect exported SQL routine counts & validate duplicate SQL overload signatures
  var sqlNameCounts = initTable[string, int]()
  var seenSqlSignatures = initTable[string, string]()
  for modIdx in 0 ..< orderedModules.len:
    for el in orderedModules[modIdx].ast:
      if el.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef}:
        if isInitProc(el) or isWorkerProc(el) or isImportc(el) or isGenericRoutine(el) or isNoSqlRoutine(el):
          continue
        let (role, _) = getFnRole(el)
        let isExp = isExportedProc(el) or role.len > 0
        if not isExp:
          continue
        let fnNameStr = el.name.repr.strip(chars = {'*'})
        if role.len == 0:
          sqlNameCounts[fnNameStr] = sqlNameCounts.getOrDefault(fnNameStr, 0) + 1
          let params = extractParamSqlTypes(el)
          var paramKeys: seq[string] = @[]
          var rawTypes: seq[string] = @[]
          for p in params:
            rawTypes.add(p.sqlType)
            paramKeys.add(normalizeSqlTypeKey(p.sqlType))
          let sigKey = fnNameStr & "(" & paramKeys.join(",") & ")"
          if sigKey in seenSqlSignatures:
            error("❌ SQL overload signature collision for '" & fnNameStr & "(" & rawTypes.join(", ") &
                  ")': collides with '" & seenSqlSignatures[sigKey] & "'", el)
          seenSqlSignatures[sigKey] = rawTypes.join(", ")

  # Pass 2b: Process routines across all modules, rewrite init procs, mangle overloads
  var chainedInitSymbols: seq[string] = @[]
  for modIdx in 0 ..< orderedModules.len:
    let modInfo = orderedModules[modIdx]
    var initSeq = 0
    for stmtIdx in 0 ..< modInfo.ast.len:
      let el = modInfo.ast[stmtIdx]
      if el.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef}:
        if el.kind in {nnkProcDef, nnkFuncDef} and isInitProc(el):
          let exportSym = "pgx_mod_init_" & modInfo.modId & "_" & $initSeq
          inc initSeq
          chainedInitSymbols.add(exportSym)
          let initNimName = newIdentNode("pgxInitPart_" & $initSeq & "_" & modInfo.modId)
          el[0] = nnkPostfix.newTree(newIdentNode("*"), initNimName)
          var newPragmas = newNimNode(nnkPragma)
          newPragmas.add(newIdentNode("cdecl"))
          newPragmas.add(newColonExpr(newIdentNode("exportc"), newLit(exportSym)))
          el.pragma = newPragmas
          continue

        if el.kind in {nnkProcDef, nnkFuncDef} and isWorkerProc(el):
          buildGuardedWorkerBody(el)
          continue

        if isImportc(el):
          continue

        if isGenericRoutine(el) or isNoSqlRoutine(el):
          injectStackDepthGuard(el)
          continue

        let (role, declaredTargetType) = getFnRole(el)
        let isExp = isExportedProc(el) or role.len > 0
        if not isExp:
          injectStackDepthGuard(el)
          continue
        if isExp:
          let fnNameStr = el.name.repr.strip(chars = {'*'})
          if role.len > 0:
            let cSym = "pgx_" & fnNameStr
            orderedModules[modIdx].v1Fns.add newIdentNode(cSym)
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
              of "output": info.outputFn = fnNameStr
              of "receive": info.receiveFn = fnNameStr
              of "send": info.sendFn = fnNameStr
              else: discard
              baseTypes[targetType] = info
              sql_base_type_fns.add buildBaseTypeFunctionSQL(el, role, targetType, cSym, prjName)
            else:
              var snap: RoutineSchema
              sql_functions.add buildSQLFunction(el, cSym, prjName, snap)
              routineSnaps.add(snap)
            if el.pragma.kind == nnkEmpty:
              el.pragma = newNimNode(nnkPragma)
            el.pragma.add(newIdentNode("pgx"))
          else:
            let isOverloaded = sqlNameCounts.getOrDefault(fnNameStr, 1) > 1
            var rawParamTypes: seq[string] = @[]
            for p in extractParamSqlTypes(el):
              rawParamTypes.add(p.sqlType)
            let cSym = buildMangledCSymbol(fnNameStr, rawParamTypes)
            orderedModules[modIdx].v1Fns.add newIdentNode(cSym)
            var snap: RoutineSchema
            sql_functions.add buildSQLFunction(el, cSym, prjName, snap)
            routineSnaps.add(snap)
            if custom_datatypes.len > 0:
              lift_base_datatypes(el, custom_datatypes)
            if el.pragma.kind == nnkEmpty:
              el.pragma = newNimNode(nnkPragma)
            if isOverloaded:
              el.pragma.add(newColonExpr(newIdentNode("pgxOverloadSym"), newLit(cSym)))
            else:
              el.pragma.add(newColonExpr(newIdentNode("pgxWithSym"), newLit(cSym)))

  # Pass 3: Finalize Base Type DDLs
  for typeName, info in baseTypes:
    if info.inputFn.len > 0 and info.outputFn.len > 0:
      var ddl = "\nCREATE TYPE \"" & info.name & "\" (\n"
      ddl.add "  INPUT = " & info.inputFn & ",\n"
      ddl.add "  OUTPUT = " & info.outputFn
      if info.receiveFn.len > 0:
        ddl.add ",\n  RECEIVE = " & info.receiveFn
      if info.sendFn.len > 0:
        ddl.add ",\n  SEND = " & info.sendFn
      ddl.add ",\n  LIKE = " & info.sqlBaseType & "\n);\n"
      sql_base_type_ddls.add ddl
      let shellDdl = "CREATE TYPE \"" & info.name & "\";\n"
      let fnPrefix = sql_base_type_fns.strip()
      baseSnaps.add BaseTypeSchema(
        name: info.name,
        ddl: shellDdl & (if fnPrefix.len > 0: fnPrefix & "\n" else: "") & ddl.strip()
      )

  var sql_scripts = ""
  sql_scripts.add sql_shell_types
  sql_scripts.add sql_base_type_fns
  sql_scripts.add sql_base_type_ddls
  sql_scripts.add sql_enums
  sql_scripts.add sql_objects
  sql_scripts.add sql_functions

  createDir(realOutDir)
  let controlContent = renderControlFile(meta)
  writeFile(realOutDir / (prjName & ".control"), controlContent)
  writeFile(realOutDir / (prjName & ".sql"), sql_scripts)
  let targetVersionSql = realOutDir / (prjName & "--" & meta.version & ".sql")
  writeFile(targetVersionSql, sql_scripts)

  # Structured schema snapshot & automatic migration generation
  let curSnapshot = SchemaSnapshot(
    version: meta.version,
    enums: enumSnaps,
    composites: compSnaps,
    baseTypes: baseSnaps,
    routines: routineSnaps
  )
  let buildDir = projectDir / ".pgx_build"
  let snapSqlDir = buildDir / "sql_snapshots"
  createDir(buildDir)
  createDir(snapSqlDir)
  let lastVerPath = buildDir / "last_version.txt"
  let curSnapJsonPath = buildDir / ("schema_" & meta.version & ".json")
  let curSnapSqlPath = snapSqlDir / (prjName & "--" & meta.version & ".sql")

  if fileExists(lastVerPath):
    let prevVer = readFile(lastVerPath).strip()
    if prevVer.len > 0 and prevVer != meta.version:
      let prevSnapPath = buildDir / ("schema_" & prevVer & ".json")
      if fileExists(prevSnapPath):
        let prevSnap = jsonToSnapshot(parseJson(readFile(prevSnapPath)))
        let migDir = projectDir / "migrations"
        createDir(migDir)
        let prevBaseSqlPath = snapSqlDir / (prjName & "--" & prevVer & ".sql")
        let migPrevBasePath = migDir / (prjName & "--" & prevVer & ".sql")
        if fileExists(prevBaseSqlPath) and not fileExists(migPrevBasePath):
          writeFile(migPrevBasePath, readFile(prevBaseSqlPath))
        let migUpgradePath = migDir / (prjName & "--" & prevVer & "--" & meta.version & ".sql")
        if not fileExists(migUpgradePath):
          let migSql = diffSnapshotsAndBuildMigration(prevSnap, curSnapshot)
          writeFile(migUpgradePath, migSql)

  writeFile(curSnapJsonPath, pretty(snapshotToJson(curSnapshot)))
  writeFile(curSnapSqlPath, sql_scripts)
  writeFile(lastVerPath, meta.version)

  # Pass 4: Emit decorated AST for every staged local module
  for modIdx in 0 ..< orderedModules.len:
    let m = orderedModules[modIdx]
    var filteredSrc = newNimNode(nnkStmtList)
    for stmt in m.ast:
      if isPgxTopImport(stmt):
        let stripped = stripPgxTopImport(stmt)
        if stripped.kind != nnkEmpty:
          filteredSrc.add(stripped)
      else:
        filteredSrc.add(stmt)

    var res = newNimNode(nnkStmtList)
    res.add newNimNode(nnkImportStmt).add newIdentNode("pgxcrown")
    if m.isMain:
      res.add newIdentNode("PG_MODULE_MAGIC")
    else:
      res.add newIdentNode("PGX_SUBMODULE_HEADERS")

    for el in filteredSrc:
      res.add el

    if not m.isMain:
      let anchorSym = newIdentNode("pgxModAnchor_" & m.modId)
      res.add quote do:
        const `anchorSym`* {.used.} = true

    for anch in m.importAnchors:
      if anch.alias.len > 0:
        let aliasIdent = newIdentNode(anch.alias)
        let anchorSym = newIdentNode(anch.anchorIdent)
        res.add quote do:
          discard `aliasIdent`.`anchorSym`
      else:
        let anchorSym = newIdentNode(anch.anchorIdent)
        res.add quote do:
          discard `anchorSym`

    for el in m.v1Fns:
      res.add quote do:
        PG_FUNCTION_INFO_V1(`el.repr`)

    if m.isMain:
      if hasPgxSharedVars or chainedInitSymbols.len > 0:
        var combinedInitCalls = newStmtList()
        if chainedInitSymbols.len == 0:
          combinedInitCalls.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
        else:
          for i, sym in chainedInitSymbols:
            let fwdProc = newIdentNode("pgxFwdModInit_" & $i)
            combinedInitCalls.add quote do:
              proc `fwdProc`() {.cdecl, importc: `sym`.}
              `fwdProc`()
        let autoInitName = newIdentNode("pgxCombinedPgInit")
        let guardedInitBody = buildGuardedInitBody(combinedInitCalls)
        res.add quote do:
          proc `autoInitName`() {.cdecl, exportc: "_PG_init", dynlib, stackTrace: off.} =
            `guardedInitBody`

      res.add newNimNode(nnkPragma).add(
        newColonExpr(
          newIdentNode("emit"),
          newLit("""
#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) int pgx_force_libc_alloc = 0;
__attribute__((constructor(101))) static void pgx_pre_nim_init(void) {
  pgx_force_libc_alloc++;
}
static void pgx_post_nim_init(void) {
  if (pgx_force_libc_alloc > 0) {
    pgx_force_libc_alloc--;
  }
}
#else
static void pgx_post_nim_init(void) {}
#endif
""")
        )
      )
      let postInitIdent = newIdentNode("pgxPostNimInitHook")
      res.add quote do:
        proc `postInitIdent`() {.importc: "pgx_post_nim_init", nodecl.}
        `postInitIdent`()

    writeFile(m.path, res.repr)

    when defined(pgxDebug):
      if m.isMain:
        echo "[pgxDebug] Extension meta (", meta.source, "): version=", meta.version,
             " relocatable=", meta.relocatable, " trusted=", meta.trusted,
             " schema=", meta.schema, " requires=", meta.requires.join(",")
        echo "[pgxDebug] Generated SQL DDL for extension '", prjName, "':\n", sql_scripts
      echo "[pgxDebug] Decorated AST for '", m.path, "':\n", res.repr

decorateMainFunctions()
