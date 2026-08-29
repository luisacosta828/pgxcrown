import std/[macros, strutils, macrocache]

const 
  pgxFunctions = CacheTable"pgxfn"
  pgxVarDecl   = CacheTable"pgxvar"
  pgxEnums     = CacheTable"pgxenum"
  pgxTupleConstr     = CacheTable"pgxTupleConstr"
  pgxObjectTy        = CacheTable"pgxObjectTy"
  currentPGXCustomType = CacheTable"pgxcustomtype"
  anonTuplConstr = CacheTable"anonTuplConstr"  

var 
  cacheIteration {.compileTime.} = 0
  fnIdx {.compileTime.} = 0


proc checkPgxTypeDef(dt: string): string =
  var idx: string = $cacheIteration & "type"
  if dt in pgxEnums:
    currentPGXCustomType[idx] = ident("enum")
    result = "getOid"
  elif dt.startsWith("seq["):
    result = "getArrayHeapTuples"
  else:
    currentPGXCustomType[idx] = ident("object")
    result = "getHeapTupleHeader"

proc checkNimTypeDef(dt: string): string =
  if dt in pgxEnums: 
    result = "Oid"
  else:
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
  of "char": "cchar"
  of "bool": "bool"
  of "string": "string"
  of "cstring": "cstring"
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNode"
  else: 
    checkNimTypeDef(dt)

template PgxToNim(dt: string): string =
  case dt
  of "int", "int32": "getInt32"
  of "int16": "getInt16"
  of "uint16": "getUInt16"
  of "int64": "getInt64"
  of "char": "getChar"
  of "bool": "getBool"
  of "uint", "uint32": "getUInt32"
  of "float", "float32": "getFloat4"
  of "float64": "getFloat8"
  of "string": "TextDatumGetCString"
  of "cstring": "getCString" 
  of "JsonNode", "Json", "json", "Jsonb", "jsonb": "getJsonNode"
  of "seq[int]", "seq[int32]": "getArrayInt32"
  of "seq[int64]": "getArrayInt64"
  of "seq[float]", "seq[float32]", "seq[float64]": "getArrayFloat64"
  of "seq[bool]": "getArrayBool"
  of "seq[string]": "getArrayString"
  else: 
    if dt.startsWith("seq["):
      "getArrayHeapTuples"
    else:
      checkPgxTypeDef(dt) 


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
  if node.kind == nnkReturnStmt:
    return true
  if node.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkTemplateDef, nnkMacroDef}:
    return false
  
  for child in node:
    if hasReturn(child):
      return true
      
  return false


template map_enums_params(pvar, ptype) =
  var 
    ncall: NimNode
    ncallident: NimNode

  ncall = newCall(ident("DirectFunctionCall1"), [ident("enum_out"), newCall(ident("ObjectIdGetDatum"), [ident(pvar&"_oid")])])

  ncall = newCall(ident("DatumToCString"), [ncall])
  ncall = newCall(ident("$"),[ncall])

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

template move_nim_params_as_locals =
  var pvar: string
  var ptype: string

  for i in 1..fnparams_len:
    let identDef = fn.params[i]
    pvar = identDef[0].repr
    let typeNode = identDef[^2]
    let defaultNode = identDef[^1]

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

    ptype = innerTypeStr
    var f = PgxToNim(ptype)
    let argIdxVal = cuint(i - 1)
    var argIdxNode = newIntLitNode(i - 1)
    var rawFetch: NimNode

    if ptype.startsWith("seq["):
      rawFetch = newCall(ident(f), [newCall(ident("getDatum"), [argIdxNode])])
    elif ptype != "string":
      if isOptionParam:
        rawFetch = newCall(innerTypeNode, [newCall(ident(f), [argIdxNode])])
      else:
        rawFetch = newCall(ident(f), [argIdxNode])
    else:
      rawFetch = newCall(ident("$"), [newCall(ident(f), [newCall(ident("getDatum"), [argIdxNode])])])

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
      getValue = newTree(nnkIfExpr,
        newTree(nnkElifBranch,
          newCall(ident("isArgNull"), newLit(argIdxVal)),
          defaultNode
        ),
        newTree(nnkElse,
          rawFetch
        )
      )
    else:
      let zeroVal = case ptype
        of "string": newLit("")
        of "bool": newLit(false)
        of "int", "int32", "cint": newLit(int32(0))
        of "int64": newLit(int64(0))
        of "float", "float64": newLit(float64(0.0))
        of "JsonNode", "Json", "json", "Jsonb", "jsonb": newCall(ident("newJNull"))
        else:
          if ptype.startsWith("seq["):
            newTree(nnkPrefix, ident("@"), newTree(nnkBracket, newSeq[NimNode]()))
          else:
            rawFetch
      if zeroVal != rawFetch:
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

    let isPrimitiveOrJson = ptype in ["int", "int32", "int16", "uint16", "int64", "char", "bool", "uint", "uint32", "float", "float32", "float64", "string", "cstring", "JsonNode", "Json", "json", "Jsonb", "jsonb"]
    let isPrimitiveSeq = ptype in ["seq[int]", "seq[int32]", "seq[int64]", "seq[float]", "seq[float32]", "seq[float64]", "seq[bool]", "seq[string]", "seq[JsonNode]", "seq[Jsonb]", "seq[jsonb]"]
    var idx = $cacheIteration & "type"
    var enumVisited = enum_visited(idx)

    if isOptionParam:
      if isPrimitiveOrJson or isPrimitiveSeq:
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
    elif isPrimitiveOrJson or isPrimitiveSeq:
      varSection.add(newIdentDefs(ident(pvar), typeNode, getValue))
    elif enumVisited:
      map_enums_params(pvar, ptype)
      varSection.add(newIdentDefs(ident(pvar), ident(NimTypes(ptype)), getValue))
    elif ptype.startsWith("seq["):
      let innerElemTypeNode = typeNode[1]
      let callObjSeq = newCall(newTree(nnkBracketExpr, ident("seqTupleHeaderToObjects"), innerElemTypeNode), newCall(ident("getDatum"), argIdxNode))
      varSection.add(newIdentDefs(ident(pvar), typeNode, callObjSeq))
    else:
      let callObj = newCall(newTree(nnkBracketExpr, ident("tupleHeaderToObject"), typeNode), getValue)
      varSection.add(newIdentDefs(ident(pvar), typeNode, callObj))
    cacheIteration += 1

  if fn.params[0].kind != nnkEmpty:
    varSection.add(newIdentDefs(nnkPragmaExpr.newTree(ident("userResult"), newTree(nnkPragma, ident("used"))), fn.params[0], newEmptyNode()))

template copy_fn_body =
  let body_lines = fn.body.len - 2
  for lines in 0..body_lines:
    rbody.add fn.body[lines]


template call_return_macro(fn_call: string, code: NimNode): NimNode =
  newCall(return_macro, [code])

proc check_infix_section(code: NimNode): NimNode
proc check_literal_values(code: NimNode): NimNode
proc check_return_section(code: NimNode): NimNode
proc check_call_section(code: NimNode): NimNode
proc check_var_section(code: NimNode): NimNode
proc check_if_section(code: NimNode): NimNode 
proc check_case_section(code: NimNode): NimNode 
proc check_asgn_section(code: NimNode): NimNode
proc check_block_section(code: NimNode): NimNode
proc check_discard_section(code: NimNode): NimNode
proc check_while_section(code: NimNode): NimNode
proc check_for_section(code: NimNode): NimNode
proc check_proc_def(code: NimNode): NimNode
proc analyze_node(code: NimNode): NimNode

proc check_infix_section(code: NimNode): NimNode =
  result = code
  result[1] = analyze_node(code[1])
  result[2] = analyze_node(code[2])
    
proc check_literal_values(code: NimNode): NimNode =
  var return_macro = "return" & ReplyLiteralsWithPgxTypes(code)
  call_return_macro(return_macro, code)

proc check_return_section(code: NimNode): NimNode =
  #result = newNimNode(code.kind)
  result = newTree(nnkStmtList)
  
  for key, value in anonTuplConstr:
    if "fn" & $fnIdx in key:
      #call tupdesc destructor
      let tuple_destructor = anonTuplConstr[key]
      result.add tuple_destructor
      

  code[0] = analyze_node(code[0])
  result.add code

proc check_discard_section(code: NimNode): NimNode =
  result = check_return_section(code)

proc check_block_section(code: NimNode): NimNode = analyze_node(code)

proc check_proc_def(code: NimNode): NimNode =
  result = code

proc analyze_node(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  case code.kind:
  of nnkVarSection:
    result = check_var_section(code)
  of nnkAsgn:
    result = check_asgn_section(code)
  of nnkCall: 
    if code[0].repr == "echo":
      result = newCall(ident("report"), [ident("notice"), code[1]]) 
    else:    
      result = check_call_section(code)
  of nnkCommand:
    if code[0].repr == "echo":
      result = newCall(ident("report"), [ident("notice"), code[1]]) 
    else:
      result = code
    
  of nnkBlockStmt:
    result.add code[0]
    result.add check_block_section(code[1])
  of nnkLiterals:
    result = code
  of nnkIdent:
    if code.repr == "result":
      result = ident("userResult")
    else:
      result = code
  of nnkBracketExpr:
    result = newNimNode(nnkBracketExpr)
    for child in code:
      result.add analyze_node(child)
  of nnkForStmt:
    result = check_for_section(code)
  of nnkInfix:
    result = check_infix_section(code)
  of nnkStmtList:
    for instruction in code:
      result.add analyze_node(instruction)
  of nnkIfExpr, nnkIfStmt:
    result = check_if_section(code)
  of nnkCaseStmt:
    result = check_case_section(code)
  of nnkReturnStmt:
    result = check_return_section(code)
  of nnkDiscardStmt:
    result = check_discard_section(code)
  of nnkWhileStmt:
    result = check_while_section(code)
  of nnkProcDef, nnkFuncDef:
    result = check_proc_def(code)
  of nnkPrefix, nnkDotExpr, nnkEmpty, nnkCommentStmt, nnkTypeSection, nnkTypeDef, nnkObjectTy, nnkRecList, nnkEnumTy, nnkEnumFieldDef, nnkRefTy, nnkPtrTy, nnkDistinctTy, nnkTupleTy, nnkBracket, nnkCurly, nnkPar, nnkSym, nnkLambda, nnkDo, nnkAccQuoted, nnkFormalParams, nnkTableConstr, nnkTupleConstr, nnkObjConstr, nnkConv, nnkHiddenStdConv, nnkHiddenSubConv, nnkStmtListExpr, nnkElifBranch, nnkElse, nnkOfBranch, nnkPragma, nnkExprColonExpr, nnkPragmaExpr, nnkExprEqExpr:
    if code.len == 0:
      result = code
    else:
      result = newNimNode(code.kind)
      for child in code:
        result.add analyze_node(child)
  of nnkTryStmt, nnkExceptBranch, nnkConstSection, nnkLetSection, nnkConstDef, nnkIdentDefs, nnkCast:
    for child in code:
      result.add analyze_node(child)
  else:
    raise newException(Exception, "Unsupported instruction: " & $code.treerepr)

proc check_call_section(code: NimNode):NimNode =
  var 
    fn_name:string = code[0].repr
    pgx_args:seq[NimNode]
    is_pgx_fn:bool = fn_name in pgxFunctions

  template check_args(code) = 
    for props in code[1 .. ^1]:
      pgx_args.add analyze_node(props)

  if is_pgx_fn:
    pgx_args.add ident("pgx_" & fn_name)

  check_args(code)

  result = 
    if is_pgx_fn:
      newCall(ident("DirectFunctionCall" & $(pgx_args.len - 1)), pgx_args)
    else:
      newCall(code[0], pgx_args)


proc check_var_section(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  for identdef in code:
    result.add newIdentDefs(
      identdef[0],
      identdef[1],
      analyze_node(identdef[2])
    )

proc check_if_section(code: NimNode): NimNode = 
  var branchSection = newNimNode(code.kind)
  for stmt in code:
    var new_node = newNimNode(stmt.kind)
    if stmt.kind == nnkElifBranch:
      new_node.add analyze_node(stmt[0])
      new_node.add analyze_node(stmt[1])
    elif stmt.kind == nnkElse:
      new_node.add analyze_node(stmt[0])
    else:
      for child in stmt:
        new_node.add analyze_node(child)
    branchSection.add new_node
  return branchSection

proc check_case_section(code: NimNode): NimNode =
  var caseSection = newNimNode(code.kind)
  caseSection.add code[0]
  for stmt in code[1 .. ^1]:
    var new_node = newNimNode(stmt.kind)
    if stmt.kind != nnkElse:
      new_node.add analyze_node(stmt[0])
    new_node.add analyze_node(stmt[^1])
    caseSection.add new_node
  return caseSection

proc check_while_section(code: NimNode): NimNode =
  var whileSection = newNimNode(code.kind)
  for stmt in code:
    whileSection.add analyze_node(stmt)
  return whileSection

proc check_for_section(code: NimNode): NimNode =
  var forSection = newNimNode(code.kind)
  forSection.add code[0]
  for stmt in code[1 .. ^1]:
    forSection.add analyze_node(stmt)
  return forSection


proc check_asgn_section(code: NimNode): NimNode =
  result = code
  result[0] = analyze_node(code[0])
  result[1] = analyze_node(code[1])

proc analyze_fn_body(fn: NimNode): NimNode =
  result = newTree(nnkStmtList)
  var varSection = newNimNode(nnkVarSection)
  var asgnSection = newNimNode(nnkAsgn)
  var asgnMultiple = newNimNode(nnkStmtList)

  var fnparams_len = fn.params.len - 1
  move_nim_params_as_locals

  result.add varSection
  if asgnSection.len > 0:
    result.add asgnSection
  if asgnMultiple.len > 0:
    result.add asgnMultiple

  for item in fn.body: 
    result.add analyze_node(item)

template clean_tuple_desc = 
  if not hasReturn(rbody):
    for key, value in anonTuplConstr:
      if "fn" & $fnIdx in key:
        rbody.add anonTuplConstr[key]
  

proc wrapOptionReturn(code: NimNode, innerTypeStr: string): NimNode =
  let datumConverter = case innerTypeStr:
    of "int", "int32", "cint": "Int32GetDatum"
    of "int64", "clonglong": "Int64GetDatum"
    of "int16", "cshort": "Int16GetDatum"
    of "float", "float32", "cfloat": "Float4GetDatum"
    of "float64", "cdouble": "Float8GetDatum"
    of "bool": "BoolGetDatum"
    of "string": "CStringGetTextDatum"
    of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNodeToDatum"
    else: "objectToDatum"

  proc transformReturn(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt:
      let optVal = ident("optValTemp")
      let retExpr = if n[0].kind == nnkEmpty: ident("userResult") else: n[0]
      let convIdent = ident(datumConverter)
      if innerTypeStr == "string":
        return quote do:
          block:
            let `optVal` = `retExpr`
            if `optVal`.isNone:
              returnNull()
              return Datum(0)
            else:
              return CStringGetTextDatum(cstring(`optVal`.get))
      else:
        return quote do:
          block:
            let `optVal` = `retExpr`
            if `optVal`.isNone:
              returnNull()
              return Datum(0)
            else:
              return `convIdent`(`optVal`.get)
    elif n.len == 0:
      return n
    else:
      result = newNimNode(n.kind)
      for child in n:
        result.add transformReturn(child)

  let transformed = transformReturn(code)
  if not hasReturn(transformed):
    result = transformed
    let convIdent = ident(datumConverter)
    if innerTypeStr == "string":
      result.add quote do:
        block:
          let optValTemp = userResult
          if optValTemp.isNone:
            returnNull()
            return Datum(0)
          else:
            return CStringGetTextDatum(cstring(optValTemp.get))
    else:
      result.add quote do:
        block:
          let optValTemp = userResult
          if optValTemp.isNone:
            returnNull()
            return Datum(0)
          else:
            return `convIdent`(optValTemp.get)
  else:
    result = transformed

proc wrapSeqReturn(code: NimNode, retTypeStr: string): NimNode =
  let elemTypeStr = retTypeStr[4 .. ^2]
  let datumConverter = case elemTypeStr:
    of "int", "int32", "cint": "Int32GetDatum"
    of "int64", "clonglong": "Int64GetDatum"
    of "int16", "cshort": "Int16GetDatum"
    of "float", "float32", "cfloat": "Float4GetDatum"
    of "float64", "cdouble": "Float8GetDatum"
    of "bool": "BoolGetDatum"
    of "string": "CStringGetTextDatum"
    of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNodeToDatum"
    else: "objectToDatum"

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

  let convIdent = ident(datumConverter)
  let elemTypeNode = ident(elemTypeStr)
  let typeNode = newTree(nnkBracketExpr, ident("seq"), elemTypeNode)

  let srfStateIdent = ident("SrfState")
  let funcctxIdent = ident("funcctx")
  let oldcontextIdent = ident("oldcontext")
  let stateObjIdent = ident("stateObj")
  let callCntrIdent = ident("callCntr")
  let maxCallsIdent = ident("maxCalls")
  let itemValIdent = ident("itemVal")
  let itemDatumIdent = ident("itemDatum")

  result = quote do:
    type `srfStateIdent` = ref object
      items: `typeNode`
    var `funcctxIdent` {.importc: "funcctx", nodecl.}: FuncCallContextPtr
    if SRF_IS_FIRSTCALL():
      var `oldcontextIdent` {.importc: "oldcontext", nodecl.}: pointer
      `funcctxIdent` = SRF_FIRSTCALL_INIT()
      `oldcontextIdent` = MemoryContextSwitchTo(`funcctxIdent`.multi_call_memory_ctx)
      `transformedCode`
      var `stateObjIdent` = `srfStateIdent`(items: userResult)
      GC_ref(`stateObjIdent`)
      `funcctxIdent`.user_fctx = cast[pointer](`stateObjIdent`)
      `funcctxIdent`.max_calls = cast[uint64](userResult.len)
      discard MemoryContextSwitchTo(`oldcontextIdent`)

    `funcctxIdent` = SRF_PERCALL_SETUP()
    let `callCntrIdent` = `funcctxIdent`.call_cntr
    let `maxCallsIdent` = `funcctxIdent`.max_calls
    let `stateObjIdent` = cast[`srfStateIdent`](`funcctxIdent`.user_fctx)
    if `callCntrIdent` < `maxCallsIdent` and `stateObjIdent` != nil:
      let `itemValIdent` = `stateObjIdent`.items[`callCntrIdent`]
      let `itemDatumIdent` = `convIdent`(`itemValIdent`)
      SRF_RETURN_NEXT(`funcctxIdent`, `itemDatumIdent`)
    else:
      if `stateObjIdent` != nil:
        GC_unref(`stateObjIdent`)
      SRF_RETURN_DONE(`funcctxIdent`)

proc wrapScalarReturn(code: NimNode, retTypeStr: string): NimNode =
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

  let datumConverter = case retTypeStr:
    of "int", "int32", "cint": "Int32GetDatum"
    of "int64", "clonglong": "Int64GetDatum"
    of "int16", "cshort": "Int16GetDatum"
    of "float", "float32", "cfloat": "Float4GetDatum"
    of "float64", "cdouble": "Float8GetDatum"
    of "bool": "BoolGetDatum"
    of "string", "cstring": "CStringGetTextDatum"
    of "JsonNode", "Json", "json", "Jsonb", "jsonb": "JsonNodeToDatum"
    else: "objectToDatum"

  proc transformReturn(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt:
      let retExpr = if n[0].kind == nnkEmpty: ident("userResult") else: n[0]
      if retExpr.kind == nnkCall and (retExpr[0].repr.endsWith("GetDatum") or retExpr[0].repr in ["JsonNodeToDatum", "objectToDatum"]):
        return n
      elif retTypeStr == "cstring":
        if retExpr.kind == nnkCall and retExpr[0].repr == "CStringGetDatum":
          return n
        else:
          return newTree(nnkReturnStmt, newCall(ident("CStringGetDatum"), newCall(ident("pstrdup"), newCall(ident("cstring"), retExpr))))
      elif retTypeStr in ["string", "Text"]:
        if retExpr.kind == nnkCall and retExpr[0].repr == "CStringGetTextDatum":
          return n
        else:
          return newTree(nnkReturnStmt, newCall(ident("CStringGetTextDatum"), newCall(ident("cstring"), retExpr)))
      elif retTypeStr in ["JsonNode", "Json", "json", "Jsonb", "jsonb"]:
        if retExpr.kind == nnkCall and retExpr[0].repr == "JsonNodeToDatum":
          return n
        else:
          return newTree(nnkReturnStmt, newCall(ident("JsonNodeToDatum"), retExpr))
      elif retTypeStr in ["int", "int32", "cint"]:
        return newTree(nnkReturnStmt, newCall(ident("Int32GetDatum"), newCall(ident("int32"), retExpr)))
      elif retTypeStr in ["int64", "clonglong"]:
        return newTree(nnkReturnStmt, newCall(ident("Int64GetDatum"), newCall(ident("int64"), retExpr)))
      elif retTypeStr in ["int16", "cshort"]:
        return newTree(nnkReturnStmt, newCall(ident("Int16GetDatum"), newCall(ident("int16"), retExpr)))
      elif retTypeStr in ["float", "float32", "cfloat"]:
        return newTree(nnkReturnStmt, newCall(ident("Float4GetDatum"), newCall(ident("float32"), retExpr)))
      elif retTypeStr in ["float64", "cdouble"]:
        return newTree(nnkReturnStmt, newCall(ident("Float8GetDatum"), newCall(ident("float64"), retExpr)))
      elif retTypeStr in ["bool"]:
        return newTree(nnkReturnStmt, newCall(ident("BoolGetDatum"), newCall(ident("bool"), retExpr)))
      elif retTypeStr in ["uint", "uint32"]:
        return newTree(nnkReturnStmt, newCall(ident("UInt32GetDatum"), newCall(ident("uint32"), retExpr)))
      elif retTypeStr in ["uint64"]:
        return newTree(nnkReturnStmt, newCall(ident("UInt64GetDatum"), newCall(ident("uint64"), retExpr)))
      else:
        return newTree(nnkReturnStmt, newCall(ident(datumConverter), retExpr))
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
    if retTypeStr in ["string", "cstring"]:
      result.add newTree(nnkReturnStmt, newCall(ident("CStringGetTextDatum"), newCall(ident("cstring"), ident("userResult"))))
    elif retTypeStr in ["JsonNode", "Json", "json", "Jsonb", "jsonb"]:
      result.add newTree(nnkReturnStmt, newCall(ident("JsonNodeToDatum"), ident("userResult")))
    else:
      result.add newTree(nnkReturnStmt, newCall(ident(datumConverter), ident("userResult")))
  else:
    result = transformed

proc isStatement(n: NimNode): bool =
  case n.kind:
  of nnkAsgn, nnkVarSection, nnkLetSection, nnkConstSection, nnkTypeSection,
     nnkDiscardStmt, nnkBreakStmt, nnkContinueStmt, nnkIfStmt, nnkWhenStmt,
     nnkWhileStmt, nnkForStmt, nnkBlockStmt, nnkStmtList:
    true
  of nnkCall, nnkInfix:
    if n.len > 0 and n[0].kind == nnkIdent and n[0].repr in ["[]=", "add", "del", "delete", "insert", "inc", "dec"]:
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

proc explainWrapper(fn: NimNode): NimNode =
  checkSecurityPragmas(fn)
  let pgx_proc = newProc(ident("pgx_" & $fn.name), proc_type = nnkProcDef)
  pgxFunctions[fn.name.repr] = fn.params
  pgx_proc.params[0] = ident("Datum")

  var isImmutable = false
  var isStable = false
  if fn.pragma.kind != nnkEmpty:
    for p in fn.pragma:
      let pRepr = p.repr.toLowerAscii
      if pRepr in ["immutable"]:
        isImmutable = true
      elif pRepr in ["stable"]:
        isStable = true

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

  var trustedPragma = newNimNode(nnkPragma)
  trustedPragma.add(ident("pgv1"))
  trustedPragma.add(ident("trusted"))
  trustedPragma.add(forbidsExpr)
  if isImmutable:
    trustedPragma.add(ident("noSideEffect"))

  pgx_proc.pragma = trustedPragma

  var rbody = newTree(nnkStmtList)

  rbody = analyze_fn_body(fn)

  let retTypeStr = if fn.params[0].kind != nnkEmpty: fn.params[0].repr else: ""
  let isOptionReturn = fn.params[0].kind == nnkBracketExpr and fn.params[0][0].repr == "Option"
  let isSeqReturn = retTypeStr.startsWith("seq[")

  if isSeqReturn:
    rbody = wrapSeqReturn(rbody, retTypeStr)
  elif isOptionReturn:
    let innerTypeStr = fn.params[0][1].repr
    if not hasReturn(rbody) and fn.params[0].kind != nnkEmpty and rbody.len > 0:
      if isStatement(rbody[^1]):
        rbody.add newTree(nnkReturnStmt, ident("userResult"))
      else:
        rbody[^1] = newTree(nnkReturnStmt, rbody[^1])
    rbody = wrapOptionReturn(rbody, innerTypeStr)
  else:
    if not hasReturn(rbody) and fn.params[0].kind != nnkEmpty and rbody.len > 0:
      if isStatement(rbody[^1]):
        rbody.add newTree(nnkReturnStmt, ident("userResult"))
      else:
        rbody[^1] = newTree(nnkReturnStmt, rbody[^1])
    rbody = wrapScalarReturn(rbody, retTypeStr)

  var shieldedBody = newTree(nnkTryStmt,
    rbody,
    newTree(nnkExceptBranch,
      newTree(nnkInfix, ident("as"), ident("Defect"), ident("e")),
      newTree(nnkStmtList,
        newCall(ident("reportError"), 
          newTree(nnkInfix, ident("&"), 
            newTree(nnkInfix, ident("&"), 
              newTree(nnkInfix, ident("&"), 
                newLit("Extension Defect ["), 
                newTree(nnkPrefix, ident("$"), newTree(nnkDotExpr, ident("e"), ident("name")))
              ),
              newLit("]: ")
            ),
            newTree(nnkDotExpr, ident("e"), ident("msg"))
          )
        )
      )
    ),
    newTree(nnkExceptBranch,
      newTree(nnkInfix, ident("as"), ident("CatchableError"), ident("e")),
      newTree(nnkStmtList,
        newCall(ident("reportError"), 
          newTree(nnkInfix, ident("&"), 
            newTree(nnkInfix, ident("&"), 
              newTree(nnkInfix, ident("&"), 
                newLit("Extension Error ["), 
                newTree(nnkPrefix, ident("$"), newTree(nnkDotExpr, ident("e"), ident("name")))
              ),
              newLit("]: ")
            ),
            newTree(nnkDotExpr, ident("e"), ident("msg"))
          )
        )
      )
    )
  )

  pgx_proc.body = shieldedBody
  echo pgx_proc.repr
  
  result = pgx_proc
  fnIdx += 1

proc registerPGXEnum(obj: NimNode) = pgxEnums[obj[0][0].repr] = obj
proc registerPGXTupleConstr(obj: NimNode) = pgxTupleConstr[obj[0][0].repr] = obj
proc registerPGXObjectTy(obj: NimNode) = pgxObjectTy[obj[0][0].repr] = obj

macro pgx*(fn: untyped): untyped = 
  if fn.kind != nnkTypeDef:
    return explainWrapper(fn) 
  else:
    case fn[2].kind:
    of nnkEnumTy:
      registerPGXEnum(fn)
      return fn
    of nnkTupleConstr:
      registerPGXTupleConstr(fn)
      return fn
    of nnkObjectTy:
      registerPGXObjectTy(fn)
      return fn 
    else:
      discard
  
