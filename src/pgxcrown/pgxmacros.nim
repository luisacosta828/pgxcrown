import std/[macros, strutils, macrocache]

const 
  pgxFunctions = CacheTable"pgxfn"
  pgxOverloadedNames = CacheTable"pgxoverloaded"
  pgxVarDecl   = CacheTable"pgxvar"
  pgxEnums     = CacheTable"pgxenum"
  pgxDistinct  = CacheTable"pgxDistinct"
  pgxTupleConstr     = CacheTable"pgxTupleConstr"
  pgxObjectTy        = CacheTable"pgxObjectTy"
  currentPGXCustomType = CacheTable"pgxcustomtype"
  anonTuplConstr = CacheTable"anonTuplConstr"  

var 
  cacheIteration {.compileTime.} = 0
  fnIdx {.compileTime.} = 0

proc stripStars(s: string): string {.compileTime.} =
  s.strip(chars = {'*'}).strip()

proc cachePutIfAbsent(tbl: CacheTable, key: string, val: NimNode) {.compileTime.} =
  if key notin tbl:
    tbl[key] = val

proc checkPgxTypeDef(dt: string): string =
  var idx: string = $cacheIteration & "type"
  if dt in pgxEnums:
    currentPGXCustomType[idx] = ident("enum")
    result = "getOid"
  elif dt in pgxDistinct:
    currentPGXCustomType[idx] = ident("distinct")
    result = "getDatum"
  elif dt.startsWith("seq["):
    result = "getArrayHeapTuples"
  else:
    currentPGXCustomType[idx] = ident("object")
    result = "getHeapTupleHeader"

proc checkNimTypeDef(dt: string): string =
  result = dt

template NimTypes(dt: string): string =
  case dt
  of "int", "int32": "cint"
  of "int16": "cshort"
  of "int8": "int8"
  of "uint", "uint32": "culong"
  of "float", "float32": "cfloat"
  of "float64": "cdouble"
  of "int64": "clonglong"
  of "uint64": "culonglong"
  of "uint16": "cushort"
  of "uint8": "uint8"
  of "char": "cchar"
  of "bool": "bool"
  of "string": "string"
  of "cstring": "cstring"
  of "PgText": "PgText"
  of "PgBytea": "PgBytea"
  of "PgUuid": "PgUuid"
  of "PgDate": "PgDate"
  of "PgTimestamp": "PgTimestamp"
  of "PgTimestampTz": "PgTimestampTz"
  of "PgInterval": "PgInterval"
  of "PgNumeric": "PgNumeric"
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNode"
  else: 
    checkNimTypeDef(dt)

template PgxToNim(dt: string): string =
  case dt
  of "int", "int32": "getInt32"
  of "int16": "getInt16"
  of "int8": "getInt8"
  of "uint16": "getUInt16"
  of "uint8": "getUInt8"
  of "int64": "getInt64"
  of "uint64": "getUInt64"
  of "char": "getChar"
  of "bool": "getBool"
  of "uint", "uint32": "getUInt32"
  of "float", "float32": "getFloat4"
  of "float64": "getFloat8"
  of "string", "PgText": "getPgText"
  of "cstring": "getCString"
  of "PgBytea": "getPgBytea"
  of "PgUuid": "getPgUuid"
  of "PgDate": "getPgDate"
  of "PgTimestamp": "getPgTimestamp"
  of "PgTimestampTz": "getPgTimestampTz"
  of "PgInterval": "getPgInterval"
  of "PgNumeric": "getPgNumeric"
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": "getJsonNode"
  of "seq[int]", "seq[int32]": "getArrayInt32"
  of "seq[int64]": "getArrayInt64"
  of "seq[float]", "seq[float32]", "seq[float64]": "getArrayFloat64"
  of "seq[bool]": "getArrayBool"
  of "seq[string]": "getArrayString"
  of "seq[PgUuid]": "getArrayPgUuid"
  of "seq[PgBytea]": "getArrayPgBytea"
  of "seq[PgDate]": "getArrayPgDate"
  of "seq[PgTimestamp]": "getArrayPgTimestamp"
  of "seq[PgTimestampTz]": "getArrayPgTimestampTz"
  of "seq[PgInterval]": "getArrayPgInterval"
  of "seq[PgNumeric]": "getArrayPgNumeric"
  of "seq[JsonNode]", "seq[Jsonb]", "seq[jsonb]": "getArrayJsonNode"
  of "PgVector[float64]": "getPgVectorFloat64"
  of "PgVector[float32]", "PgVector[float]": "getPgVectorFloat32"
  of "PgVector[int32]", "PgVector[int]": "getPgVectorInt32"
  of "PgVector[int64]": "getPgVectorInt64"
  of "PgVector[int16]": "getPgVectorInt16"
  of "PgVector[bool]": "getPgVectorBool"
  else: 
    if dt.startsWith("seq["):
      "getArrayHeapTuples"
    else:
      checkPgxTypeDef(dt)

proc isDatumFetchedParam(dt: string): bool {.compileTime.} =
  dt in [
    "PgText", "PgBytea", "PgUuid", "PgDate", "PgTimestamp",
    "PgTimestampTz", "PgInterval", "PgNumeric",
    "JsonNode", "Json", "json", "Jsonb", "jsonb"
  ] or dt.startsWith("seq[") or dt.startsWith("PgVector[")

proc isBuiltinParamOrSeq(dt: string): bool {.compileTime.} =
  dt in [
    "int", "int32", "int16", "int8", "int64", "char", "bool",
    "uint", "uint32", "uint16", "uint8", "uint64",
    "float", "float32", "float64", "string", "cstring",
    "PgText", "PgBytea", "PgUuid", "PgDate", "PgTimestamp",
    "PgTimestampTz", "PgInterval", "PgNumeric",
    "JsonNode", "Json", "json", "Jsonb", "jsonb",
    "seq[int]", "seq[int32]", "seq[int64]", "seq[float]", "seq[float32]",
    "seq[float64]", "seq[bool]", "seq[string]",
    "seq[PgUuid]", "seq[PgBytea]", "seq[PgDate]", "seq[PgTimestamp]",
    "seq[PgTimestampTz]", "seq[PgInterval]", "seq[PgNumeric]",
    "seq[JsonNode]", "seq[Jsonb]", "seq[jsonb]"
  ] or dt.startsWith("PgVector[")

proc zeroExprForType(dt: string, typeNode: NimNode): NimNode {.compileTime.} =
  case dt
  of "string": newLit("")
  of "cstring": newLit("")
  of "char": newLit('\0')
  of "PgText": newTree(nnkObjConstr, ident("PgText"))
  of "PgBytea": newCall(ident("initPgBytea"))
  of "PgUuid": newCall(ident("nilUuid"))
  of "PgDate", "PgTimestamp", "PgTimestampTz", "PgInterval": newTree(nnkObjConstr, ident(dt))
  of "PgNumeric": newCall(ident("initPgNumericZero"))
  of "bool": newLit(false)
  of "int", "int32", "cint": newLit(int32(0))
  of "int16": newLit(int16(0))
  of "int8": newLit(int8(0))
  of "int64": newLit(int64(0))
  of "uint", "uint32": newLit(uint32(0))
  of "uint16": newLit(uint16(0))
  of "uint8": newLit(uint8(0))
  of "uint64": newLit(uint64(0))
  of "float", "float32": newLit(float32(0.0))
  of "float64": newLit(float64(0.0))
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": newCall(ident("newJNull"))
  else:
    if dt.startsWith("seq["):
      newTree(nnkPrefix, ident("@"), newTree(nnkBracket, newSeq[NimNode]()))
    elif dt.startsWith("PgVector["):
      newTree(nnkObjConstr, typeNode)
    elif dt in pgxEnums:
      newCall(ident("default"), ident(dt))
    elif dt in pgxDistinct:
      newCall(ident("default"), ident(dt))
    else:
      newEmptyNode()

proc buildRawParamFetch(dt: string, typeNode: NimNode, argIdxNode: NimNode, forOption: bool): NimNode {.compileTime.} =
  if dt in pgxEnums:
    return newCall(newTree(nnkBracketExpr, ident("oidToEnum"), ident(dt)),
                   newCall(ident("getOid"), argIdxNode))
  if dt in pgxDistinct:
    let baseStr = stripStars(pgxDistinct[dt].repr)
    if baseStr == "string":
      let txtFetch = newCall(ident("$"), newCall(ident("getPgText"), newCall(ident("getDatum"), argIdxNode)))
      return newCall(ident(dt), txtFetch)
    let baseFetch = buildRawParamFetch(baseStr, ident(baseStr), argIdxNode, forOption = true)
    return newCall(ident(dt), baseFetch)
  if dt.startsWith("seq["):
    let elemStr = stripStars(dt[4 .. ^2])
    if elemStr in pgxEnums:
      return newCall(newTree(nnkBracketExpr, ident("getArrayEnum"), ident(elemStr)),
                     newCall(ident("getDatum"), argIdxNode))
    elif elemStr in pgxDistinct:
      let baseStr = stripStars(pgxDistinct[elemStr].repr)
      let baseSeqType = "seq[" & baseStr & "]"
      let baseSeqFetch = buildRawParamFetch(baseSeqType, newTree(nnkBracketExpr, ident("seq"), ident(baseStr)), argIdxNode, forOption = false)
      let resSeq = ident("distinctSeqTmp")
      let loopIt = ident("distinctSeqItem")
      let elemIdent = ident(elemStr)
      let baseIdent = ident(baseStr)
      return quote do:
        block:
          let rawItems = `baseSeqFetch`
          var `resSeq` = newSeq[`elemIdent`](rawItems.len)
          for k, `loopIt` in rawItems:
            `resSeq`[k] = `elemIdent`(`baseIdent`(`loopIt`))
          `resSeq`
  let f = PgxToNim(dt)
  if isDatumFetchedParam(dt):
    newCall(ident(f), [newCall(ident("getDatum"), [argIdxNode])])
  elif dt != "string":
    if forOption and dt in ["int", "int32", "int16", "int8", "uint", "uint32", "uint16", "uint8", "int64", "uint64", "float", "float32", "float64", "bool", "char"]:
      newCall(typeNode, [newCall(ident(f), [argIdxNode])])
    else:
      newCall(ident(f), [argIdxNode])
  else:
    newCall(ident("$"), [newCall(ident(f), [newCall(ident("getDatum"), [argIdxNode])])])


proc ReplyWithPgxTypes(dt: string): string =
  case dt
  of "cint", "int", "int32": "Int32"
  of "cfloat","float", "float32": "Float4"
  of "cdouble","float64": "Float8"
  else: "unknown"

proc ReplyLiteralsWithPgxTypes(dt: NimNode): string =
  case dt.kind:
  of nnkIntLit, nnkInt32Lit: "Int32"
  of nnkInt16Lit: "Int16"
  of nnkUInt32Lit: "UInt32"
  of nnkUInt16Lit: "UInt16"
  of nnkFloatLit, nnkFloat32Lit: "Float4"
  of nnkFloat64Lit: "Float8"
  else: ""

proc hasReturn(node: NimNode): bool =
  case node.kind
  of nnkReturnStmt, nnkRaiseStmt:
    return true
  of nnkStmtList, nnkStmtListExpr, nnkBlockStmt:
    if node.len > 0:
      return hasReturn(node[^1])
    return false
  of nnkIfStmt, nnkIfExpr:
    var hasElse = false
    for branch in node:
      if branch.kind in {nnkElse, nnkElseExpr}:
        hasElse = true
      if branch.len == 0 or not hasReturn(branch[^1]):
        return false
    return hasElse
  of nnkCaseStmt:
    if node.len <= 1:
      return false
    for i in 1 ..< node.len:
      let branch = node[i]
      if branch.len == 0 or not hasReturn(branch[^1]):
        return false
    return true
  else:
    return false



template map_enums_params(pvar, ptype) =
  var ncall = newCall(ident("enumOidToString"), [ident(pvar & "_oid")])

  var 
    genericPart = nnkBracketExpr.newTree(ident("parseEnum"),ident(ptype))
    parseEnumCall = nnkCall.newTree(genericPart, ncall, ident("PgxUnknownValue"))

  varSection.add newIdentDefs(ident(pvar), ident(ptype))
  asgnSection.add(ident(pvar), parseEnumCall)
  pvar = pvar & "_oid"


template map_tuplec_params(pvar, ptype, param) =
  var tupvar = ident("tupDesc" & $cacheIteration & "fn" & $fnIdx)

  varSection.add newIdentDefs(tupvar, ident("TupleDesc"), newEmptyNode())
  varSection.add param

  anonTuplConstr[tupvar.repr] = newCall(ident("DecrTupleDescRefCount"), [tupvar])
 
  var treestmt = newNimNode(nnkStmtList)

  var callTupDescLookup = newCall(ident("getTupleDesc"), [ident(pvar & "th")])
  var asgn1 = newNimNode(nnkAsgn).add(tupvar, callTupDescLookup)

  treestmt.add(asgn1)

  var i = 0
  var formalParam: NimNode
  let paramTypeStr = param[1].repr
  let objKey = if paramTypeStr in pgxObjectTy: paramTypeStr
               elif (paramTypeStr & "*") in pgxObjectTy: (paramTypeStr & "*")
               else: ""
  let tupKey = if paramTypeStr in pgxTupleConstr: paramTypeStr
               elif (paramTypeStr & "*") in pgxTupleConstr: (paramTypeStr & "*")
               else: ""

  if tupKey.len > 0:
    formalParam = pgxTupleConstr[tupKey][2]
  elif objKey.len > 0:
    formalParam = pgxObjectTy[objKey][2]
  
  if formalParam.kind == nnkTupleConstr:
    for dtype in formalParam:
      let 
        pgIdx = newLit((i + 1).int16)
        nimIdx = newLit(i)
      
        call = nnkAsgn.newTree(
          nnkBracketExpr.newTree(ident(pvar), nimIdx),
          nnkCall.newTree(
            nnkBracketExpr.newTree(ident("get_tuple_attr"), dtype),
            ident(pvar & "th"),
            tupvar,
          pgIdx))
  
      treestmt.add(call)
      i += 1

    pvar = pvar & "th"
    asgnMultiple.add treestmt

  elif formalParam.kind == nnkObjectTy:
    for dtype in formalParam[2]:
      let pgIdx = newLit((i+1).int16)
      let call = nnkAsgn.newTree(
        nnkDotExpr.newTree(
          ident(pvar),
          dtype[0]
        ),
        nnkCall.newTree(
        nnkBracketExpr.newTree(ident("get_tuple_attr"), dtype[1]),
        ident(pvar & "th"),
        tupvar, pgIdx
      ))
      treestmt.add(call)
      i += 1

    pvar = pvar & "th"
    asgnMultiple.add treestmt

template map_seq_tuplec_params(pvar, elemTypeStr, param, argIdxNode) =
  var thSeqVar = ident(pvar & "ThSeq")
  var tupvar = ident("tupDesc" & $cacheIteration & "fn" & $fnIdx)
  
  varSection.add newIdentDefs(thSeqVar, newTree(nnkBracketExpr, ident("seq"), ident("HeapTupleHeader")), newCall(ident("getArrayHeapTuples"), newCall(ident("getDatum"), argIdxNode)))
  varSection.add newIdentDefs(ident(pvar), param[^2], newCall(newTree(nnkBracketExpr, ident("newSeq"), ident(elemTypeStr)), newDotExpr(thSeqVar, ident("len"))))

  var treestmt = newNimNode(nnkStmtList)
  var loopIdx = ident("seqIdx" & $cacheIteration)

  var formalParam: NimNode
  let objKey = if elemTypeStr in pgxObjectTy: elemTypeStr
               elif (elemTypeStr & "*") in pgxObjectTy: (elemTypeStr & "*")
               else: ""
  let tupKey = if elemTypeStr in pgxTupleConstr: elemTypeStr
               elif (elemTypeStr & "*") in pgxTupleConstr: (elemTypeStr & "*")
               else: ""

  if tupKey.len > 0:
    formalParam = pgxTupleConstr[tupKey][2]
  elif objKey.len > 0:
    formalParam = pgxObjectTy[objKey][2]

  var loopBody = newNimNode(nnkStmtList)
  let itemTh = ident("itemTh")
  loopBody.add newTree(nnkLetSection, newIdentDefs(itemTh, ident("HeapTupleHeader"), newTree(nnkBracketExpr, thSeqVar, loopIdx)))

  var ifStmt = newNimNode(nnkIfExpr)
  var ifBody = newNimNode(nnkStmtList)

  let tupDescCall = newCall(ident("getTupleDesc"), itemTh)
  ifBody.add newTree(nnkLetSection, newIdentDefs(tupvar, ident("TupleDesc"), tupDescCall))

  var fieldIdx = 0
  if formalParam != nil and formalParam.kind == nnkTupleConstr:
    for dtype in formalParam:
      let pgIdx = newLit((fieldIdx + 1).int16)
      let nimIdx = newLit(fieldIdx)
      let rawDatum = newCall(newTree(nnkBracketExpr, ident("get_tuple_attr"), ident("Datum")), itemTh, tupvar, pgIdx)
      let ftypeStr = dtype.repr
      let typedVal = case ftypeStr
        of "int", "int32", "cint": newCall(ident("DatumGetInt32"), rawDatum)
        of "int64": newCall(ident("DatumGetInt64"), rawDatum)
        of "float", "float64": newCall(ident("DatumGetFloat8"), rawDatum)
        of "bool": newTree(nnkInfix, ident("!="), rawDatum, newIntLitNode(0))
        of "string": newCall(ident("$"), newCall(ident("getTupleStringAttr"), itemTh, tupvar, pgIdx))
        else: rawDatum
      ifBody.add newTree(nnkAsgn, newTree(nnkBracketExpr, newTree(nnkBracketExpr, ident(pvar), loopIdx), nimIdx), typedVal)
      fieldIdx += 1
  elif formalParam != nil and formalParam.kind == nnkObjectTy:
    let recordFields = formalParam[2]
    for identDefs in recordFields:
      for fieldNameNode in identDefs[0 .. ^3]:
        let fieldNameIdent = if fieldNameNode.kind == nnkPostfix: fieldNameNode[1] else: fieldNameNode
        let fieldType = identDefs[^2]
        let ftypeStr = fieldType.repr
        let pgIdx = newLit((fieldIdx + 1).int16)
        let rawDatum = newCall(newTree(nnkBracketExpr, ident("get_tuple_attr"), ident("Datum")), itemTh, tupvar, pgIdx)
        let typedVal = case ftypeStr
          of "int", "int32", "cint": newCall(ident("DatumGetInt32"), rawDatum)
          of "int64": newCall(ident("DatumGetInt64"), rawDatum)
          of "float", "float64": newCall(ident("DatumGetFloat8"), rawDatum)
          of "bool": newTree(nnkInfix, ident("!="), rawDatum, newIntLitNode(0))
          of "string": newCall(ident("$"), newCall(ident("getTupleStringAttr"), itemTh, tupvar, pgIdx))
          else: rawDatum
        ifBody.add newTree(nnkAsgn, newDotExpr(newTree(nnkBracketExpr, ident(pvar), loopIdx), fieldNameIdent), typedVal)
        fieldIdx += 1

  ifBody.add newCall(ident("DecrTupleDescRefCount"), tupvar)

  ifStmt.add newTree(nnkElifBranch, newTree(nnkInfix, ident("!="), itemTh, newNilLit()), ifBody)
  loopBody.add ifStmt

  let forLoop = newTree(nnkForStmt, loopIdx, newTree(nnkInfix, ident("..<"), newLit(0), newDotExpr(thSeqVar, ident("len"))), loopBody)
  treestmt.add forLoop
  asgnMultiple.add treestmt

template get_param_type(parameter): string =
  var validType = parameter[1].kind == nnkIdent
  if validType:
    parameter[1].repr
  else:
    parameter[1].kind.repr

template enum_visited(idx): bool = idx in currentPGXCustomType and currentPGXCustomType[idx].repr == "enum"
template tuplec_visited(idx): bool = idx in currentPGXCustomType and currentPGXCustomType[idx].repr == "tupleConstr"
template object_visited(idx): bool = idx in currentPGXCustomType and currentPGXCustomType[idx].repr == "object"

proc wrapCtxCloneExpr(expr: NimNode, dtNorm: string, cloneInCtx: bool): NimNode {.compileTime.} =
  if not cloneInCtx:
    return expr
  case dtNorm
  of "PgText":
    newCall(ident("clonePgTextInCtx"), expr)
  of "PgBytea":
    newCall(ident("toPgBytea"), newCall(ident("toBytes"), expr))
  of "PgNumeric":
    newCall(ident("clonePgNumericInCtx"), expr)
  of "seq[PgBytea]":
    let rawSeq = genSym(nskLet, "rawByteaSeq")
    let resSeq = genSym(nskVar, "clonedByteaSeq")
    let loopIdx = genSym(nskForVar, "idx")
    quote do:
      block:
        let `rawSeq` = `expr`
        var `resSeq` = newSeq[PgBytea](`rawSeq`.len)
        for `loopIdx` in 0 ..< `rawSeq`.len:
          `resSeq`[`loopIdx`] = toPgBytea(toBytes(`rawSeq`[`loopIdx`]))
        `resSeq`
  of "seq[PgNumeric]":
    let rawSeq = genSym(nskLet, "rawNumSeq")
    let resSeq = genSym(nskVar, "clonedNumSeq")
    let loopIdx = genSym(nskForVar, "idx")
    quote do:
      block:
        let `rawSeq` = `expr`
        var `resSeq` = newSeq[PgNumeric](`rawSeq`.len)
        for `loopIdx` in 0 ..< `rawSeq`.len:
          `resSeq`[`loopIdx`] = clonePgNumericInCtx(`rawSeq`[`loopIdx`])
        `resSeq`
  else:
    if dtNorm.startsWith("PgVector["):
      newCall(ident("clonePgVectorInCtx"), expr)
    else:
      expr

proc buildParamDecls(fn: NimNode, varSection: NimNode, cloneInCtx: bool, addUserResult: bool) {.compileTime.} =
  var argPos = 0
  for i in 1 ..< fn.params.len:
    let identDef = fn.params[i]
    if identDef.kind != nnkIdentDefs or identDef.len < 3:
      continue
    let origTypeNode = identDef[^2]
    let defaultNode = identDef[^1]
    for nameIdx in 0 ..< identDef.len - 2:
      let pvar = stripStars(identDef[nameIdx].repr)
      var typeNode = origTypeNode
      var isOptionParam = false
      var innerTypeStr = ""
      var innerTypeNode: NimNode

      if typeNode.kind == nnkBracketExpr and typeNode[0].repr == "Option":
        isOptionParam = true
        innerTypeStr = typeNode[1].repr
        innerTypeNode = typeNode[1]
      else:
        innerTypeStr = typeNode.repr
        innerTypeNode = typeNode

      var ptype = stripStars(innerTypeStr)

      let isNumericSeq = case ptype:
        of "seq[float64]", "seq[float32]", "seq[float]", "seq[int32]", "seq[int]", "seq[int64]", "seq[int16]", "seq[bool]": true
        else: false

      if isNumericSeq:
        case ptype:
        of "seq[float64]":
          ptype = "PgVector[float64]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("float64"))
        of "seq[float32]", "seq[float]":
          ptype = "PgVector[float32]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("float32"))
        of "seq[int32]", "seq[int]":
          ptype = "PgVector[int32]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("int32"))
        of "seq[int64]":
          ptype = "PgVector[int64]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("int64"))
        of "seq[int16]":
          ptype = "PgVector[int16]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("int16"))
        of "seq[bool]":
          ptype = "PgVector[bool]"
          innerTypeNode = newTree(nnkBracketExpr, ident("PgVector"), ident("bool"))
        else: discard
        typeNode = if isOptionParam: newTree(nnkBracketExpr, ident("Option"), innerTypeNode) else: innerTypeNode

      let isStringType = (ptype == "string" or ptype == "PgText")
      if isStringType:
        ptype = "PgText"
        innerTypeNode = ident("PgText")
        typeNode = if isOptionParam: newTree(nnkBracketExpr, ident("Option"), innerTypeNode) else: innerTypeNode

      let ptypeNorm = stripStars(ptype)
      let argIdxVal = cuint(argPos)
      let argIdxNode = newIntLitNode(argPos)
      inc argPos

      let isEnumParam = ptypeNorm in pgxEnums
      let isDistinctParam = ptypeNorm in pgxDistinct
      let elemSeqStr = if ptypeNorm.startsWith("seq["): stripStars(ptypeNorm[4 .. ^2]) else: ""
      let isEnumOrDistinctSeq = elemSeqStr.len > 0 and (elemSeqStr in pgxEnums or elemSeqStr in pgxDistinct)
      let isKnownScalar = isBuiltinParamOrSeq(ptypeNorm) or isEnumParam or isDistinctParam or isEnumOrDistinctSeq

      let rawFetch = wrapCtxCloneExpr(
        buildRawParamFetch(ptypeNorm, innerTypeNode, argIdxNode, forOption = isOptionParam),
        ptypeNorm,
        cloneInCtx
      )

      var getValue: NimNode
      if isOptionParam:
        getValue = newTree(nnkIfExpr,
          newTree(nnkElifBranch,
            newCall(ident("isArgNull"), newLit(argIdxVal)),
            newCall(ident("none"), innerTypeNode)
          ),
          newTree(nnkElse,
            newCall(ident("some"), rawFetch)
          )
        )
      elif defaultNode.kind != nnkEmpty:
        let defVal =
          if isStringType:
            wrapCtxCloneExpr(newCall(ident("toPgText"), defaultNode), "PgText", cloneInCtx)
          else:
            defaultNode
        getValue = newTree(nnkIfExpr,
          newTree(nnkElifBranch,
            newCall(ident("isArgNull"), newLit(argIdxVal)),
            defVal
          ),
          newTree(nnkElse,
            rawFetch
          )
        )
      else:
        let zeroVal = zeroExprForType(ptypeNorm, typeNode)
        if zeroVal.kind != nnkEmpty:
          getValue = newTree(nnkIfExpr,
            newTree(nnkElifBranch,
              newCall(ident("isArgNull"), newLit(argIdxVal)),
              zeroVal
            ),
            newTree(nnkElse,
              rawFetch
            )
          )
        else:
          getValue = rawFetch

      if isOptionParam:
        if isKnownScalar:
          varSection.add(newIdentDefs(ident(pvar), typeNode, getValue))
        else:
          let rawOptFetch = newTree(nnkIfExpr,
            newTree(nnkElifBranch,
              newCall(ident("isArgNull"), newLit(argIdxVal)),
              newCall(ident("none"), innerTypeNode)
            ),
            newTree(nnkElse,
              newCall(ident("some"), newCall(newTree(nnkBracketExpr, ident("tupleHeaderToObject"), innerTypeNode), rawFetch))
            )
          )
          varSection.add(newIdentDefs(ident(pvar), typeNode, rawOptFetch))
      elif isKnownScalar:
        varSection.add(newIdentDefs(ident(pvar), typeNode, getValue))
      elif ptypeNorm.startsWith("seq["):
        let innerElemTypeNode = typeNode[1]
        let callObjSeq = newCall(newTree(nnkBracketExpr, ident("seqTupleHeaderToObjects"), innerElemTypeNode), newCall(ident("getDatum"), argIdxNode))
        varSection.add(newIdentDefs(ident(pvar), typeNode, callObjSeq))
      else:
        let callObj = newCall(newTree(nnkBracketExpr, ident("tupleHeaderToObject"), typeNode), getValue)
        varSection.add(newIdentDefs(ident(pvar), typeNode, callObj))
      cacheIteration += 1

  if addUserResult and fn.params[0].kind != nnkEmpty:
    varSection.add(newIdentDefs(nnkPragmaExpr.newTree(ident("userResult"), newTree(nnkPragma, ident("used"))), fn.params[0], newEmptyNode()))

template move_nim_params_as_locals =
  buildParamDecls(fn, varSection, cloneInCtx = false, addUserResult = true)

template copy_fn_body =
  let body_lines = fn.body.len - 2
  for lines in 0..body_lines:
    rbody.add fn.body[lines]


template call_return_macro(fn_call: string, code: NimNode): NimNode =
  newCall(return_macro, [code])

proc analyzeNode*(code: NimNode, rewriteResult: bool = true): NimNode

proc check_infix_section(code: NimNode, rewriteResult: bool): NimNode =
  result = code
  result[1] = analyzeNode(code[1], rewriteResult)
  result[2] = analyzeNode(code[2], rewriteResult)

proc check_call_section_impl(code: NimNode, rewriteResult: bool): NimNode

proc check_return_section_impl(code: NimNode, rewriteResult: bool): NimNode =
  result = newTree(nnkStmtList)
  for key, value in anonTuplConstr:
    if "fn" & $fnIdx in key:
      let tuple_destructor = anonTuplConstr[key]
      result.add tuple_destructor
  code[0] = analyzeNode(code[0], rewriteResult)
  result.add code

proc check_proc_def(code: NimNode): NimNode =
  if code.len >= 7 and code[^1].kind != nnkEmpty:
    var isImp = false
    if code.pragma.kind != nnkEmpty:
      for p in code.pragma:
        let pName = (if p.kind == nnkExprColonExpr: p[0].repr else: p.repr).toLowerAscii
        if pName == "importc":
          isImp = true
          break
    if not isImp:
      var res = copyNimTree(code)
      res[^1] = newStmtList(
        newCall(ident("checkStackDepth")),
        analyzeNode(code[^1], rewriteResult = false)
      )
      return res
  result = code

proc analyzeNode*(code: NimNode, rewriteResult: bool = true): NimNode =
  result = newNimNode(code.kind)
  case code.kind:
  of nnkVarSection:
    result = newNimNode(code.kind)
    for identdef in code:
      result.add newIdentDefs(identdef[0], identdef[1], analyzeNode(identdef[2], rewriteResult))
  of nnkAsgn:
    result = code
    result[0] = analyzeNode(code[0], rewriteResult)
    result[1] = analyzeNode(code[1], rewriteResult)
  of nnkCall:
    if code[0].repr == "echo":
      result = newCall(ident("report"), [ident("notice"), analyzeNode(code[1], rewriteResult)])
    else:
      result = check_call_section_impl(code, rewriteResult)
  of nnkCommand:
    if code[0].repr == "echo":
      result = newCall(ident("report"), [ident("notice"), analyzeNode(code[1], rewriteResult)])
    elif code[0].kind == nnkIdent and (stripStars(code[0].repr) in pgxFunctions or stripStars(code[0].repr) in pgxOverloadedNames):
      let fn_name = stripStars(code[0].repr)
      error("❌ Cannot call exported SQL UDF '" & fn_name & "' directly from Nim. Move shared pure-Nim logic into the 'private/' directory, an unexported helper proc, or mark it with {.noSql.}.", code)
    else:
      result.add code[0]
      for i in 1 ..< code.len:
        result.add analyzeNode(code[i], rewriteResult)
  of nnkBlockStmt:
    result.add code[0]
    result.add analyzeNode(code[1], rewriteResult)
  of nnkLiterals:
    result = code
  of nnkIdent:
    if rewriteResult and code.repr == "result":
      result = ident("userResult")
    else:
      result = code
  of nnkBracketExpr:
    result = newNimNode(nnkBracketExpr)
    for child in code:
      result.add analyzeNode(child, rewriteResult)
  of nnkForStmt:
    result = newNimNode(code.kind)
    result.add code[0]
    for stmt in code[1 .. ^1]:
      result.add analyzeNode(stmt, rewriteResult)
  of nnkInfix:
    result = check_infix_section(code, rewriteResult)
  of nnkStmtList:
    for instruction in code:
      result.add analyzeNode(instruction, rewriteResult)
  of nnkIfExpr, nnkIfStmt:
    var branchSection = newNimNode(code.kind)
    for stmt in code:
      var new_node = newNimNode(stmt.kind)
      if stmt.kind == nnkElifBranch:
        new_node.add analyzeNode(stmt[0], rewriteResult)
        new_node.add analyzeNode(stmt[1], rewriteResult)
      elif stmt.kind == nnkElse:
        new_node.add analyzeNode(stmt[0], rewriteResult)
      else:
        for child in stmt:
          new_node.add analyzeNode(child, rewriteResult)
      branchSection.add new_node
    result = branchSection
  of nnkCaseStmt:
    var caseSection = newNimNode(code.kind)
    caseSection.add analyzeNode(code[0], rewriteResult)
    for stmt in code[1 .. ^1]:
      var new_node = newNimNode(stmt.kind)
      for child in stmt:
        new_node.add analyzeNode(child, rewriteResult)
      caseSection.add new_node
    result = caseSection
  of nnkReturnStmt:
    if rewriteResult:
      result = check_return_section_impl(code, rewriteResult)
    else:
      result = newNimNode(code.kind)
      for child in code:
        result.add analyzeNode(child, rewriteResult)
  of nnkDiscardStmt:
    if rewriteResult:
      result = check_return_section_impl(code, rewriteResult)
    else:
      result = newNimNode(code.kind)
      for child in code:
        result.add analyzeNode(child, rewriteResult)
  of nnkWhileStmt:
    result = newNimNode(code.kind)
    for stmt in code:
      result.add analyzeNode(stmt, rewriteResult)
  of nnkProcDef, nnkFuncDef:
    result = check_proc_def(code)
  of nnkPrefix, nnkDotExpr, nnkEmpty, nnkCommentStmt, nnkTypeSection, nnkTypeDef, nnkObjectTy, nnkRecList, nnkEnumTy, nnkEnumFieldDef, nnkRefTy, nnkPtrTy, nnkDistinctTy, nnkTupleTy, nnkBracket, nnkCurly, nnkPar, nnkSym, nnkLambda, nnkDo, nnkAccQuoted, nnkFormalParams, nnkTableConstr, nnkTupleConstr, nnkObjConstr, nnkConv, nnkHiddenStdConv, nnkHiddenSubConv, nnkStmtListExpr, nnkElifBranch, nnkElse, nnkElifExpr, nnkElseExpr, nnkOfBranch, nnkPragma, nnkExprColonExpr, nnkPragmaExpr, nnkExprEqExpr, nnkWhenStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt, nnkFinally, nnkDefer, nnkYieldStmt, nnkTemplateDef, nnkIteratorDef:
    if code.len == 0:
      result = code
    else:
      result = newNimNode(code.kind)
      for child in code:
        result.add analyzeNode(child, rewriteResult)
  of nnkTryStmt, nnkExceptBranch, nnkConstSection, nnkLetSection, nnkConstDef, nnkIdentDefs, nnkCast, nnkVarTuple:
    for child in code:
      result.add analyzeNode(child, rewriteResult)
  else:
    raise newException(Exception, "Unsupported instruction: " & $code.treerepr)

proc check_call_section_impl(code: NimNode, rewriteResult: bool): NimNode =
  let fn_name = stripStars(code[0].repr)
  if code[0].kind == nnkIdent and (fn_name in pgxFunctions or fn_name in pgxOverloadedNames):
    error("❌ Cannot call exported SQL UDF '" & fn_name & "' directly from Nim. Move shared pure-Nim logic into the 'private/' directory, an unexported helper proc, or mark it with {.noSql.}.", code)

  var pgx_args: seq[NimNode] = @[]
  for props in code[1 .. ^1]:
    pgx_args.add analyzeNode(props, rewriteResult)

  newCall(code[0], pgx_args)

proc analyze_fn_body(fn: NimNode): NimNode =
  result = newTree(nnkStmtList)
  var varSection = newNimNode(nnkVarSection)
  var asgnSection = newNimNode(nnkAsgn)
  var asgnMultiple = newNimNode(nnkStmtList)

  var fnparams_len {.used.} = fn.params.len - 1
  move_nim_params_as_locals

  result.add varSection
  if asgnSection.len > 0:
    result.add asgnSection
  if asgnMultiple.len > 0:
    result.add asgnMultiple

  for item in fn.body: 
    result.add analyzeNode(item)

template clean_tuple_desc = 
  if not hasReturn(rbody):
    for key, value in anonTuplConstr:
      if "fn" & $fnIdx in key:
        rbody.add anonTuplConstr[key]
  

proc resolveDatumConverter(typeStr: string): string =
  ## Maps a normalized Nim return/element type name to its PostgreSQL Datum converter proc.
  let clean = stripStars(typeStr)
  case clean:
  of "int", "int32", "cint": "Int32GetDatum"
  of "int64", "clonglong": "Int64GetDatum"
  of "int16", "cshort": "Int16GetDatum"
  of "int8": "Int8GetDatum"
  of "uint", "uint32", "cuint": "UInt32GetDatum"
  of "uint64", "culonglong": "UInt64GetDatum"
  of "uint16", "cushort": "UInt16GetDatum"
  of "uint8": "UInt8GetDatum"
  of "float", "float32", "cfloat": "Float4GetDatum"
  of "float64", "cdouble": "Float8GetDatum"
  of "bool": "BoolGetDatum"
  of "char": "CharGetDatum"
  of "string", "cstring", "Text", "PgText": "returnPgText"
  of "PgBytea": "returnPgBytea"
  of "PgUuid": "returnPgUuid"
  of "PgDate": "returnPgDate"
  of "PgTimestamp": "returnPgTimestamp"
  of "PgTimestampTz": "returnPgTimestampTz"
  of "PgInterval": "returnPgInterval"
  of "PgNumeric": "returnPgNumeric"
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNodeToDatum"
  of "PgVector[float64]": "returnPgVectorFloat64"
  of "PgVector[float32]", "PgVector[float]": "returnPgVectorFloat32"
  of "PgVector[int32]", "PgVector[int]": "returnPgVectorInt32"
  of "PgVector[int64]": "returnPgVectorInt64"
  of "PgVector[int16]": "returnPgVectorInt16"
  of "PgVector[bool]": "returnPgVectorBool"
  else:
    if clean in pgxEnums:
      "enumToDatum"
    else:
      "objectToDatum"

proc buildDatumConvExpr(typeStr: string, valExpr: NimNode, isPgxOutput: bool = false): NimNode {.compileTime.} =
  ## Builds the AST expression converting `valExpr` of Nim type `typeStr` to a PostgreSQL `Datum`.
  if isPgxOutput:
    return newCall(ident("CStringGetDatum"), newCall(ident("pstrdup"), newCall(ident("cstring"), valExpr)))
  let clean = stripStars(typeStr)
  if clean in pgxDistinct:
    let baseStr = stripStars(pgxDistinct[clean].repr)
    return buildDatumConvExpr(baseStr, newCall(ident(baseStr), valExpr), isPgxOutput = false)
  if clean in pgxEnums:
    return newCall(ident("enumToDatum"), valExpr)
  case clean
  of "cstring":
    newCall(ident("CStringGetDatum"), newCall(ident("pstrdup"), newCall(ident("cstring"), valExpr)))
  of "PgText":
    newCall(ident("returnPgText"), valExpr)
  of "string", "Text":
    newCall(ident("returnPgText"), newCall(ident("string"), valExpr))
  of "PgBytea":
    newCall(ident("returnPgBytea"), valExpr)
  of "PgUuid":
    newCall(ident("returnPgUuid"), valExpr)
  of "PgDate":
    newCall(ident("returnPgDate"), valExpr)
  of "PgTimestamp":
    newCall(ident("returnPgTimestamp"), valExpr)
  of "PgTimestampTz":
    newCall(ident("returnPgTimestampTz"), valExpr)
  of "PgInterval":
    newCall(ident("returnPgInterval"), valExpr)
  of "PgNumeric":
    newCall(ident("returnPgNumeric"), valExpr)
  of "JsonNode", "Json", "json", "Jsonb", "jsonb":
    newCall(ident("JsonNodeToDatum"), valExpr)
  of "int", "int32", "cint":
    newCall(ident("Int32GetDatum"), newCall(ident("int32"), valExpr))
  of "int64", "clonglong":
    newCall(ident("Int64GetDatum"), newCall(ident("int64"), valExpr))
  of "int16", "cshort":
    newCall(ident("Int16GetDatum"), newCall(ident("int16"), valExpr))
  of "int8":
    newCall(ident("Int8GetDatum"), newCall(ident("int8"), valExpr))
  of "float", "float32", "cfloat":
    newCall(ident("Float4GetDatum"), newCall(ident("float32"), valExpr))
  of "float64", "cdouble":
    newCall(ident("Float8GetDatum"), newCall(ident("float64"), valExpr))
  of "bool":
    newCall(ident("BoolGetDatum"), newCall(ident("bool"), valExpr))
  of "char":
    newCall(ident("CharGetDatum"), newCall(ident("cchar"), valExpr))
  of "uint", "uint32", "cuint":
    newCall(ident("UInt32GetDatum"), newCall(ident("uint32"), valExpr))
  of "uint16", "cushort":
    newCall(ident("UInt16GetDatum"), newCall(ident("uint16"), valExpr))
  of "uint8":
    newCall(ident("UInt8GetDatum"), newCall(ident("uint8"), valExpr))
  of "uint64", "culonglong":
    newCall(ident("UInt64GetDatum"), newCall(ident("uint64"), valExpr))
  else:
    newCall(ident(resolveDatumConverter(clean)), valExpr)

proc wrapOptionReturn(code: NimNode, innerTypeStr: string): NimNode =
  proc transformReturn(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt:
      let optVal = ident("optValTemp")
      let retExpr = if n[0].kind == nnkEmpty: ident("userResult") else: n[0]
      let convCall = buildDatumConvExpr(innerTypeStr, newDotExpr(optVal, ident("get")))
      return quote do:
        block:
          let `optVal` = `retExpr`
          if `optVal`.isNone:
            returnNull()
            return Datum(0)
          else:
            return `convCall`
    elif n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkTemplateDef, nnkMacroDef}:
      return n
    elif n.len == 0:
      return n
    else:
      result = newNimNode(n.kind)
      for child in n:
        result.add transformReturn(child)

  let transformed = transformReturn(code)
  if not hasReturn(transformed):
    result = transformed
    let optValTempIdent = ident("optValTemp")
    let convCall = buildDatumConvExpr(innerTypeStr, newDotExpr(optValTempIdent, ident("get")))
    result.add quote do:
      block:
        let `optValTempIdent` = userResult
        if `optValTempIdent`.isNone:
          returnNull()
          return Datum(0)
        else:
          return `convCall`
  else:
    result = transformed

proc wrapSeqReturn(code: NimNode, retTypeStr: string): NimNode =
  let elemTypeStr = stripStars(retTypeStr[4 .. ^2])

  proc replaceResult(n: NimNode): NimNode =
    if n.kind == nnkIdent and n.repr == "result":
      return ident("userResult")
    elif n.len == 0:
      return n
    else:
      result = newNimNode(n.kind)
      for child in n:
        result.add replaceResult(child)

  proc transformReturn(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt:
      let retExpr = if n[0].kind == nnkEmpty: ident("userResult") else: n[0]
      return newTree(nnkAsgn, ident("userResult"), replaceResult(retExpr))
    elif n.len == 0:
      return replaceResult(n)
    else:
      result = newNimNode(n.kind)
      for child in n:
        result.add transformReturn(child)

  let transformedCode = transformReturn(code)

  let elemTypeNode = parseExpr(elemTypeStr)
  let typeNode = newTree(nnkBracketExpr, ident("seq"), elemTypeNode)

  let srfStateIdent = ident("SrfState")
  let srfCleanupCbIdent = ident("srfCleanupCb")
  let funcctxIdent = ident("funcctx")
  let oldcontextIdent = ident("oldcontext")
  let stateObjIdent = ident("stateObj")
  let resetCbIdent = ident("resetCb")
  let callCntrIdent = ident("callCntr")
  let maxCallsIdent = ident("maxCalls")
  let itemValIdent = ident("itemVal")
  let itemDatumIdent = ident("itemDatum")
  let datumConvCall = buildDatumConvExpr(elemTypeStr, itemValIdent)

  result = quote do:
    type `srfStateIdent` = object
      items: `typeNode`
      cleanedUp: bool

    proc `srfCleanupCbIdent`(arg: pointer) {.cdecl.} =
      let st = cast[ptr `srfStateIdent`](arg)
      if st != nil and not st.cleanedUp:
        st.cleanedUp = true
        reset(st.items)

    var `funcctxIdent` {.importc: "funcctx", nodecl.}: FuncCallContextPtr
    if SRF_IS_FIRSTCALL():
      var `oldcontextIdent` {.importc: "oldcontext", nodecl.}: pointer
      `funcctxIdent` = SRF_FIRSTCALL_INIT()
      `oldcontextIdent` = MemoryContextSwitchTo(`funcctxIdent`.multi_call_memory_ctx)
      try:
        `transformedCode`
        let `stateObjIdent` = cast[ptr `srfStateIdent`](palloc0(csize_t(sizeof(`srfStateIdent`))))
        `stateObjIdent`.items = move(userResult)
        `stateObjIdent`.cleanedUp = false
        let `resetCbIdent` = cast[ptr MemoryContextCallback](palloc0(csize_t(sizeof(MemoryContextCallback))))
        `resetCbIdent`.cbFunc = `srfCleanupCbIdent`
        `resetCbIdent`.arg = `stateObjIdent`
        MemoryContextRegisterResetCallback(`funcctxIdent`.multi_call_memory_ctx, `resetCbIdent`)
        `funcctxIdent`.user_fctx = `stateObjIdent`
        `funcctxIdent`.max_calls = cast[uint64](`stateObjIdent`.items.len)
      finally:
        discard MemoryContextSwitchTo(`oldcontextIdent`)

    `funcctxIdent` = SRF_PERCALL_SETUP()
    let `callCntrIdent` = `funcctxIdent`.call_cntr
    let `maxCallsIdent` = `funcctxIdent`.max_calls
    let `stateObjIdent` = cast[ptr `srfStateIdent`](`funcctxIdent`.user_fctx)
    if `callCntrIdent` < `maxCallsIdent` and `stateObjIdent` != nil:
      var `itemValIdent` = `stateObjIdent`.items[`callCntrIdent`]
      let `itemDatumIdent` = `datumConvCall`
      reset(`itemValIdent`)
      SRF_RETURN_NEXT(`funcctxIdent`, `itemDatumIdent`)
    else:
      if `stateObjIdent` != nil and not `stateObjIdent`.cleanedUp:
        `stateObjIdent`.cleanedUp = true
        reset(`stateObjIdent`.items)
      SRF_RETURN_DONE(`funcctxIdent`)

proc wrapIteratorReturn(iterBody: NimNode, fn: NimNode, forbidsExpr: NimNode, isImmutable: bool): NimNode =
  if fn.params.len == 0 or fn.params[0].kind == nnkEmpty:
    error("Exported PG iterator SRF must specify a yield return type", fn)

  let yieldRetType = fn.params[0]
  let isOptYield = yieldRetType.kind == nnkBracketExpr and yieldRetType[0].repr == "Option"
  let elemTypeStr = stripStars((if isOptYield: yieldRetType[1] else: yieldRetType).repr)

  var iterPragmas = newNimNode(nnkPragma)
  iterPragmas.add(ident("closure"))
  iterPragmas.add(forbidsExpr.copyNimTree())
  if isImmutable:
    iterPragmas.add(ident("noSideEffect"))

  let iterTyNode = newTree(
    nnkIteratorTy,
    newTree(nnkFormalParams, yieldRetType.copyNimTree()),
    iterPragmas
  )
  let iterTypeIdent = ident("SrfIterFn_" & $fnIdx)
  let srfStateIdent = ident("SrfIterState_" & $fnIdx)
  let srfCleanupCbIdent = ident("srfIterCleanupCb_" & $fnIdx)
  let srfMakeIterIdent = ident("srfMakeIter_" & $fnIdx)
  let funcctxIdent = ident("funcctx")
  let oldcontextIdent = ident("oldcontext")
  let stateObjIdent = ident("stateObj")
  let resetCbIdent = ident("resetCb")
  let userIterIdent = ident("userIter")
  let stepValIdent = ident("stepVal")
  let isDoneIdent = ident("isDone")
  let stepOldCtxIdent = ident("stepOldCtx")
  let stepErrIdent = ident("stepErr")
  let stepDefIdent = ident("stepDef")
  let itemDatumIdent = ident("itemDatum")

  var firstCallParams = newNimNode(nnkVarSection)
  buildParamDecls(fn, firstCallParams, cloneInCtx = true, addUserResult = false)

  let iterBodyWithGuard = newStmtList(
    newCall(ident("checkStackDepth")),
    iterBody
  )
  let anonIterExpr = newTree(
    nnkIteratorDef,
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    newTree(nnkFormalParams, yieldRetType.copyNimTree()),
    iterPragmas.copyNimTree(),
    newEmptyNode(),
    iterBodyWithGuard
  )

  # Build a non-capturing factory proc so any closure-env allocation happens inside
  # `funcctx.multi_call_memory_ctx` rather than on entry to `pgxImpl_*`.
  var makeIterFormalParams = newNimNode(nnkFormalParams)
  makeIterFormalParams.add(iterTypeIdent)
  var makeIterArgs: seq[NimNode] = @[]
  for vd in firstCallParams:
    if vd.kind == nnkIdentDefs and vd.len >= 3:
      let pIdent = vd[0].copyNimTree()
      let pTy = vd[1].copyNimTree()
      makeIterFormalParams.add(newIdentDefs(pIdent, pTy, newEmptyNode()))
      makeIterArgs.add(newCall(ident("move"), pIdent.copyNimTree()))

  var makeIterPragmas = newNimNode(nnkPragma)
  makeIterPragmas.add(ident("nimcall"))
  makeIterPragmas.add(forbidsExpr.copyNimTree())
  if isImmutable:
    makeIterPragmas.add(ident("noSideEffect"))

  let makeIterDef = newTree(
    nnkProcDef,
    srfMakeIterIdent,
    newEmptyNode(), newEmptyNode(),
    makeIterFormalParams,
    makeIterPragmas,
    newEmptyNode(),
    newStmtList(newTree(nnkReturnStmt, anonIterExpr))
  )
  let makeIterCall = newCall(srfMakeIterIdent, makeIterArgs)

  var firstCallSetup = newStmtList()
  if firstCallParams.len > 0:
    firstCallSetup.add(firstCallParams)
  firstCallSetup.add quote do:
    var `userIterIdent`: `iterTypeIdent` = `makeIterCall`
    let `stateObjIdent` = cast[ptr `srfStateIdent`](palloc0(csize_t(sizeof(`srfStateIdent`))))
    `stateObjIdent`.iter = move(`userIterIdent`)
    `stateObjIdent`.cleanedUp = false
    `stateObjIdent`.inStep = false
    let `resetCbIdent` = cast[ptr MemoryContextCallback](palloc0(csize_t(sizeof(MemoryContextCallback))))
    `resetCbIdent`.cbFunc = `srfCleanupCbIdent`
    `resetCbIdent`.arg = `stateObjIdent`
    MemoryContextRegisterResetCallback(`funcctxIdent`.multi_call_memory_ctx, `resetCbIdent`)
    `funcctxIdent`.user_fctx = `stateObjIdent`

  let datumEmitBranch =
    if isOptYield:
      let optDatum = buildDatumConvExpr(elemTypeStr, newDotExpr(stepValIdent, ident("get")))
      quote do:
        if `stepValIdent`.isNone:
          reset(`stepValIdent`)
          SRF_RETURN_NEXT_NULL(`funcctxIdent`)
        else:
          let `itemDatumIdent` = `optDatum`
          reset(`stepValIdent`)
          SRF_RETURN_NEXT(`funcctxIdent`, `itemDatumIdent`)
    else:
      let scalarDatum = buildDatumConvExpr(elemTypeStr, stepValIdent)
      quote do:
        let `itemDatumIdent` = `scalarDatum`
        reset(`stepValIdent`)
        SRF_RETURN_NEXT(`funcctxIdent`, `itemDatumIdent`)

  result = quote do:
    type
      `iterTypeIdent` = `iterTyNode`
      `srfStateIdent` = object
        iter: `iterTypeIdent`
        cleanedUp: bool
        inStep: bool

    proc `srfCleanupCbIdent`(arg: pointer) {.cdecl.} =
      let st = cast[ptr `srfStateIdent`](arg)
      if st != nil and not st.cleanedUp:
        st.cleanedUp = true
        if not st.inStep:
          reset(st.iter)

    `makeIterDef`

    var `funcctxIdent` {.importc: "funcctx", nodecl.}: FuncCallContextPtr
    if SRF_IS_FIRSTCALL():
      var `oldcontextIdent` {.importc: "oldcontext", nodecl.}: pointer
      `funcctxIdent` = SRF_FIRSTCALL_INIT()
      `oldcontextIdent` = MemoryContextSwitchTo(`funcctxIdent`.multi_call_memory_ctx)
      try:
        `firstCallSetup`
      finally:
        discard MemoryContextSwitchTo(`oldcontextIdent`)

    `funcctxIdent` = SRF_PERCALL_SETUP()
    let `stateObjIdent` = cast[ptr `srfStateIdent`](`funcctxIdent`.user_fctx)
    if `stateObjIdent` == nil or `stateObjIdent`.cleanedUp or `stateObjIdent`.iter == nil:
      SRF_RETURN_DONE(`funcctxIdent`)

    var `stepValIdent`: `yieldRetType`
    var `isDoneIdent` = false
    let `stepOldCtxIdent` = MemoryContextSwitchTo(`funcctxIdent`.multi_call_memory_ctx)
    `stateObjIdent`.inStep = true
    try:
      `stepValIdent` = `stateObjIdent`.iter()
      `isDoneIdent` = finished(`stateObjIdent`.iter)
    except CatchableError as `stepErrIdent`:
      `stateObjIdent`.inStep = false
      discard MemoryContextSwitchTo(`stepOldCtxIdent`)
      if not `stateObjIdent`.cleanedUp:
        `stateObjIdent`.cleanedUp = true
        reset(`stateObjIdent`.iter)
      reset(`stepValIdent`)
      raise `stepErrIdent`
    except Defect as `stepDefIdent`:
      `stateObjIdent`.inStep = false
      discard MemoryContextSwitchTo(`stepOldCtxIdent`)
      if not `stateObjIdent`.cleanedUp:
        `stateObjIdent`.cleanedUp = true
        reset(`stateObjIdent`.iter)
      reset(`stepValIdent`)
      raise `stepDefIdent`
    `stateObjIdent`.inStep = false
    discard MemoryContextSwitchTo(`stepOldCtxIdent`)

    if `isDoneIdent`:
      if not `stateObjIdent`.cleanedUp:
        `stateObjIdent`.cleanedUp = true
        reset(`stateObjIdent`.iter)
      reset(`stepValIdent`)
      SRF_RETURN_DONE(`funcctxIdent`)
    else:
      `datumEmitBranch`

proc wrapScalarReturn(code: NimNode, retTypeStr: string, isOutputFn: bool = false): NimNode =
  let isVoid = retTypeStr == "" or retTypeStr == "void"
  if isVoid:
    proc transformVoidReturn(n: NimNode): NimNode =
      if n.kind == nnkReturnStmt:
        return newTree(nnkReturnStmt, newCall(ident("Datum"), newLit(0)))
      elif n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkTemplateDef, nnkMacroDef}:
        return n
      elif n.len == 0:
        return n
      else:
        result = newNimNode(n.kind)
        for child in n:
          result.add transformVoidReturn(child)

    let transformed = transformVoidReturn(code)
    result = transformed
    if not hasReturn(transformed):
      result.add newTree(nnkReturnStmt, newCall(ident("Datum"), newLit(0)))
    return result

  proc transformReturn(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt:
      let retExpr = if n[0].kind == nnkEmpty: ident("userResult") else: n[0]
      if retExpr.kind == nnkCall and (retExpr[0].repr.endsWith("GetDatum") or
          retExpr[0].repr.startsWith("returnPg") or
          retExpr[0].repr in ["JsonNodeToDatum", "objectToDatum", "enumToDatum"]):
        return n
      return newTree(nnkReturnStmt, buildDatumConvExpr(retTypeStr, retExpr, isPgxOutput = isOutputFn))
    elif n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkTemplateDef, nnkMacroDef}:
      return n
    elif n.len == 0:
      return n
    else:
      result = newNimNode(n.kind)
      for child in n:
        result.add transformReturn(child)

  let transformed = transformReturn(code)
  if not hasReturn(transformed):
    result = transformed
    result.add newTree(nnkReturnStmt, buildDatumConvExpr(retTypeStr, ident("userResult"), isPgxOutput = isOutputFn))
  else:
    result = transformed

proc isStatement(n: NimNode): bool =
  case n.kind:
  of nnkAsgn, nnkVarSection, nnkLetSection, nnkConstSection, nnkTypeSection,
     nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkIfStmt, nnkWhenStmt,
     nnkWhileStmt, nnkForStmt, nnkBlockStmt, nnkStmtList, nnkTryStmt, nnkRaiseStmt, nnkDefer:
    true
  of nnkCaseStmt:
    for i in 1 ..< n.len:
      let branch = n[i]
      if branch.len > 0:
        let body = branch[^1]
        let lastNode =
          if body.kind == nnkStmtList and body.len > 0: body[^1]
          else: body
        if hasReturn(body) or isStatement(lastNode):
          return true
    false
  of nnkCall, nnkInfix:
    if n.len > 0 and n[0].kind == nnkIdent and n[0].repr.toLowerAscii in [
      "[]=", "add", "del", "delete", "insert", "inc", "dec",
      "withlock", "withspinlock", "withmemorycontext", "withtopmemorycontext",
      "withsubcontext", "withwaiteventset", "report", "spi_init",
      "subtransaction", "savepoint"
    ]:
      true
    else:
      false
  else:
    false

proc checkSecurityPragmas(node: NimNode) =
  case node.kind:
  of nnkPragmaBlock:
    if node.len > 0:
      let pragmaNode = node[0]
      for p in pragmaNode:
        let pRepr = p.repr
        if pRepr.startsWith("cast(") or pRepr.startsWith("cast:"):
          error("❌ [SECURITY VIOLATION] Usage of effect-evasion pragma '{" & pRepr & "}' is strictly prohibited in Pgxcrown UDFs. Database extensions cannot bypass effect sandboxing.", node)
  of nnkPragma:
    for p in node:
      let pRepr = p.repr
      if pRepr.startsWith("cast(") or pRepr.startsWith("cast:"):
        error("❌ [SECURITY VIOLATION] Usage of effect-evasion pragma '{" & pRepr & "}' is strictly prohibited in Pgxcrown UDFs. Database extensions cannot bypass effect sandboxing.", node)
  else:
    discard

  for child in node:
    checkSecurityPragmas(child)

proc explainWrapper(fn: NimNode, customCSym: string = "", isOverloadedHint: bool = false): NimNode =
  checkSecurityPragmas(fn)
  let fnBaseName = stripStars(fn.name.repr)
  let cSym = if customCSym.len > 0: customCSym else: "pgx_" & fnBaseName
  let isOverloadedSym = isOverloadedHint or (fn.kind != nnkIteratorDef and fnBaseName in pgxFunctions)
  if fn.kind != nnkIteratorDef:
    if isOverloadedSym:
      pgxOverloadedNames.cachePutIfAbsent(fnBaseName, ident(fnBaseName))
      pgxFunctions.cachePutIfAbsent(cSym, fn.params)
    else:
      pgxFunctions.cachePutIfAbsent(fnBaseName, fn.params)

  let pgx_proc = newProc(ident(cSym), proc_type = nnkProcDef)
  pgx_proc.params[0] = ident("Datum")

  var isImmutable = false
  var isStable = false
  var isOutputFn = false
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pName = (if p.kind == nnkExprColonExpr: p[0].repr else: p.repr).toLowerAscii
      if pName in ["immutable"]:
        isImmutable = true
      elif pName in ["stable"]:
        isStable = true
      elif pName in ["pgxoutput", "pgx_output"]:
        isOutputFn = true

  var forbidsExpr = newNimNode(nnkExprColonExpr)
  forbidsExpr.add(ident("forbids"))
  var forbidsList = newNimNode(nnkBracket)
  forbidsList.add(ident("IOEffect"))
  forbidsList.add(ident("TimeEffect"))
  if isImmutable:
    forbidsList.add(ident("DbReadEffect"))
    forbidsList.add(ident("DbWriteEffect"))
  elif isStable:
    forbidsList.add(ident("DbWriteEffect"))
  forbidsExpr.add(forbidsList)

  var innerPragma = newNimNode(nnkPragma)
  innerPragma.add(ident("nimcall"))
  innerPragma.add(forbidsExpr)
  if isImmutable:
    innerPragma.add(ident("noSideEffect"))

  var trustedPragma = newNimNode(nnkPragma)
  trustedPragma.add(ident("pgv1"))
  trustedPragma.add(ident("trusted"))
  trustedPragma.add(newColonExpr(ident("stackTrace"), ident("off")))
  trustedPragma.add(forbidsExpr)
  if isImmutable:
    trustedPragma.add(ident("noSideEffect"))

  pgx_proc.pragma = trustedPragma

  var rbody = newTree(nnkStmtList)
  if fn.kind == nnkIteratorDef:
    var iterStmts = newStmtList()
    for item in fn.body:
      iterStmts.add analyzeNode(item, rewriteResult = false)
    rbody = wrapIteratorReturn(iterStmts, fn, forbidsExpr, isImmutable)
  else:
    rbody = analyze_fn_body(fn)

    let retTypeStr = if fn.params[0].kind != nnkEmpty: fn.params[0].repr else: ""
    let isOptionReturn = fn.params[0].kind == nnkBracketExpr and fn.params[0][0].repr == "Option"
    let isSeqReturn = retTypeStr.startsWith("seq[")

    proc finalizeImplicitReturn(body: var NimNode, hasRetType: bool) =
      if not hasReturn(body) and hasRetType and body.len > 0:
        if isStatement(body[^1]):
          body.add newTree(nnkReturnStmt, ident("userResult"))
        else:
          body[^1] = newTree(nnkReturnStmt, body[^1])

    let hasRetType = fn.params[0].kind != nnkEmpty
    if isSeqReturn:
      finalizeImplicitReturn(rbody, hasRetType)
      rbody = wrapSeqReturn(rbody, retTypeStr)
    elif isOptionReturn:
      let innerTypeStr = fn.params[0][1].repr
      finalizeImplicitReturn(rbody, hasRetType)
      rbody = wrapOptionReturn(rbody, innerTypeStr)
    else:
      finalizeImplicitReturn(rbody, hasRetType)
      rbody = wrapScalarReturn(rbody, retTypeStr, isOutputFn)

  let pendingErrIdent = ident("pgxPendingErr")
  let errCodeIdent = ident("pgxErrCode")
  let errMsgIdent = ident("pgxErrMsg")
  let errDetailIdent = ident("pgxErrDetail")
  let errHintIdent = ident("pgxErrHint")
  let eIdent = ident("e")

  let scopedBody = newTree(nnkBlockStmt, newEmptyNode(), rbody)
  let shieldedBody = quote do:
    var `pendingErrIdent` = false
    var `errCodeIdent`: cint = 0
    var `errMsgIdent`: cstring = nil
    var `errDetailIdent`: cstring = nil
    var `errHintIdent`: cstring = nil
    try:
      checkStackDepth()
      `scopedBody`
    except Defect as `eIdent`:
      prepareNimDefect(`eIdent`, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)
      `pendingErrIdent` = true
    except CatchableError as `eIdent`:
      prepareNimError(`eIdent`, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)
      `pendingErrIdent` = true
    if `pendingErrIdent`:
      pgxEreportFull(ERROR, `errCodeIdent`, `errMsgIdent`, `errDetailIdent`, `errHintIdent`)

  var innerProc = copyNimTree(pgx_proc)
  let innerProcIdent = ident("pgxImpl_" & fnBaseName & "_" & $fnIdx)
  innerProc[0] = innerProcIdent
  innerPragma.add(newColonExpr(ident("codegenDecl"), newLit("static $# $#(PG_FUNCTION_ARGS)")))
  innerProc.pragma = innerPragma
  innerProc.body = shieldedBody

  pgx_proc.body = quote do:
    return pgxRunV1Guarded(Datum, `innerProcIdent`)
  when defined(pgxDebug):
    echo innerProc.repr
    echo pgx_proc.repr

  result = newStmtList(innerProc, pgx_proc)
  fnIdx += 1

proc cleanMacroTypeName(node: NimNode): string =
  if node.kind == nnkPragmaExpr and node.len >= 1:
    return cleanMacroTypeName(node[0])
  stripStars(node.repr)

proc registerPGXEnum(obj: NimNode) =
  let rawName = obj[0][0].repr
  pgxEnums.cachePutIfAbsent(rawName, obj)
  pgxEnums.cachePutIfAbsent(cleanMacroTypeName(obj[0]), obj)

proc registerPGXDistinct(obj: NimNode) =
  let cleanName = cleanMacroTypeName(obj[0])
  pgxDistinct.cachePutIfAbsent(cleanName, obj[2][0])

proc registerPGXTupleConstr(obj: NimNode) =
  let rawName = obj[0][0].repr
  pgxTupleConstr.cachePutIfAbsent(rawName, obj)
  pgxTupleConstr.cachePutIfAbsent(cleanMacroTypeName(obj[0]), obj)

proc registerPGXObjectTy(obj: NimNode) =
  let rawName = obj[0][0].repr
  pgxObjectTy.cachePutIfAbsent(rawName, obj)
  pgxObjectTy.cachePutIfAbsent(cleanMacroTypeName(obj[0]), obj)

macro pgxWithSym*(customSym: static[string], fn: untyped): untyped =
  if fn.kind != nnkTypeDef:
    return explainWrapper(fn, customSym, isOverloadedHint = false)
  else:
    result = fn

macro pgxOverloadSym*(customSym: static[string], fn: untyped): untyped =
  if fn.kind != nnkTypeDef:
    return explainWrapper(fn, customSym, isOverloadedHint = true)
  else:
    result = fn

macro pgx*(fn: untyped): untyped = 
  if fn.kind != nnkTypeDef:
    return explainWrapper(fn) 
  else:
    case fn[2].kind:
    of nnkEnumTy:
      registerPGXEnum(fn)
      return fn
    of nnkDistinctTy:
      registerPGXDistinct(fn)
      return fn
    of nnkTupleConstr:
      registerPGXTupleConstr(fn)
      return fn
    of nnkObjectTy:
      registerPGXObjectTy(fn)
      return fn 
    else:
      discard
  
