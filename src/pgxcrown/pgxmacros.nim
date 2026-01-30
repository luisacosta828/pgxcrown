import std/[macros, strutils, macrocache]

const 
  pgxFunctions = CacheTable"pgxfn"
  pgxVarDecl   = CacheTable"pgxvar"
  pgxEnums     = CacheTable"pgxenum"
  currentPGXCustomType = CacheTable"pgxcustomtype"
  anonTuplConstr = CacheTable"anonTuplConstr"  

var 
  cacheIteration {.compileTime.} = 0
  fnIdx {.compileTime.} = 0


proc checkPgxTypeDef(dt: string): string =
  result = "unknown"
  var idx: string = $cacheIteration & "type"
  if dt in pgxEnums:
    currentPGXCustomType[idx] = ident("enum")
    result = "getOid"
  elif dt == "nnkTupleConstr":
    currentPGXCustomType[idx] = ident("tupleConstr")
    result = "getHeapTupleHeader"

proc checkNimTypeDef(dt: string): string =
  result = "unknown"
  if dt in pgxEnums: 
    result = "Oid"
  if dt == "nnkTupleConstr":
    result = "HeapTupleHeader"

template NimTypes(dt: string): string =
  case dt
  of "int", "int32": "cint"
  of "uint", "uint32": "culong"
  of "float", "float32": "cfloat"
  of "float64": "cdouble"
  of "int64": "clonglong"
  of "uint64": "culonglong"
  of "uint16": "cushort"
  of "char": "cchar"
  of "string": "string"
  of "cstring": "cstring"
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


template map_enums_params(pvar, ptype) =
  var 
    ncall: NimNode
    ncallident: NimNode

  ncall = newCall(ident("DirectFunctionCall1"), [ident("enum_out"), newCall(ident("ObjectIdGetDatum"), [ident(pvar&"_oid")])])
  var 
    genericPart = nnkBracketExpr.newTree(ident("parseEnum"),ident(ptype))
    parseEnumCall = nnkCall.newTree(genericPart, ncall, ident("PgxUnknownValue"))

  varSection.add newIdentDefs(ident(pvar), ident(ptype))
  asgnSection.add(ident(pvar), parseEnumCall)
  pvar = pvar & "_oid"

template map_tuplec_params(pvar, ptype, param) =
  var 
    tupvar = ident("tupDesc" & $cacheIteration & "fn" & $fnIdx)
    tuptype = ident("tupType" & $cacheIteration & "fn" & $fnIdx)
    tuptypmod = ident("tupTypmod" & $cacheIteration & "fn" & $fnIdx)

  varSection.add newIdentDefs(tuptype, ident("Oid"), newEmptyNode())
  varSection.add newIdentDefs(tuptypmod, ident("cint"), newEmptyNode())
  varSection.add newIdentDefs(tupvar, ident("TupleDesc"), newEmptyNode())
  varSection.add param

  anonTuplConstr[tupvar.repr] = newCall(ident("DecrTupleDescRefCount"), [tupvar])
 
  var treestmt = newNimNode(nnkStmtList)
  var callTypeId = newCall(ident("getTypeId2"), [ident(pvar & "th")])
  var asgn1 = newNimNode(nnkAsgn).add(tuptype, callTypeId)

  var callTypeMod = newCall(ident("getTypeMod2"), [ident(pvar & "th")]) 
  var asgn2 = newNimNode(nnkAsgn).add(tuptypmod, callTypeMod)

  var callTupDescLookup = newCall(ident("lookup_rowtype_tupdesc"), [tuptype, tuptypmod])
  var asgn3 = newNimNode(nnkAsgn).add(tupvar, callTupDescLookup)

  treestmt.add(asgn1)
  treestmt.add(asgn2)
  treestmt.add(asgn3)
  var i = 0
  for dtype in param[1]:
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

template get_param_type(parameter): string =
  var validType = parameter[1].kind == nnkIdent
  if validType:
    parameter[1].repr
  else:
    parameter[1].kind.repr

template enum_visited(idx): bool = idx in currentPGXCustomType and currentPGXCustomType[idx].repr == "enum"
template tuplec_visited(idx): bool = idx in currentPGXCustomType and currentPGXCustomType[idx].repr == "tupleConstr"

template move_nim_params_as_locals =
  var param: seq[string]
  var pvar: string
  var ptype: string

  for i in 1..fnparams_len:
    param = fn.params[i].repr.split(":")
    pvar = param[0]
    ptype = get_param_type(fn.params[i])
    var f = PgxToNim(ptype)
    var getValue: NimNode
    if ptype != "string":
      getValue = newCall(ident(f), [newIntLitNode(i-1)])
    else:
      getValue = newCall(ident("$"), [newCall(ident(f), [ newCall(ident("getDatum"), [newIntLitNode(i-1)]) ] )])


    var idx = $cacheIteration & "type"
    var enumVisited = enum_visited(idx)
    var tupleConstrVisited = tuplec_visited(idx)

    if enumVisited:
      map_enums_params(pvar, ptype)
    elif tupleConstrVisited:
      map_tuplec_params(pvar, ptype, fn.params[i])

    varSection.add(newIdentDefs(ident(pvar), ident(NimTypes(ptype)), getValue))
    cacheIteration += 1

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
  var sanitized_proc = newProc(code.name, proc_type = nnkFuncDef)
  sanitized_proc.params = code.params
  sanitized_proc.body = analyze_node(code.body)
  result = sanitized_proc

proc analyze_node(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  case code.kind:
  of nnkVarSection:
    result = check_var_section(code)
  of nnkAsgn:
    result = check_asgn_section(code)
  of nnkCall: 
    result = check_call_section(code)
  of nnkCommand:
    result = code
  of nnkBlockStmt:
    result.add code[0]
    result.add check_block_section(code[1])
  of nnkLiterals:
    result = code
  of nnkIdent:
    result = code
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
  of nnkForStmt:
    result = check_for_section(code)
  of nnkProcDef, nnkFuncDef:
    result = check_proc_def(code)
  of nnkPrefix:
    result = code
  of nnkBracketExpr:
    result = code
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


template is_datatype_present(node: NimNode) =
  if node[1].kind == nnkEmpty:
    raise newException(Exception, "data type expected: " & node.repr)

proc check_var_section(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  for identdef in code:
    is_datatype_present(identdef) 
    result.add newIdentDefs(
      identdef[0],
      identdef[1],
      analyze_node(identdef[2])
    )

proc check_if_section(code: NimNode): NimNode = 
  var branchSection = newNimNode(code.kind)
  for stmt in code:
    var new_node = newNimNode(stmt.kind)
    if stmt[0].kind == nnkInfix:
      new_node.add analyze_node(stmt[0])
    new_node.add analyze_node(stmt[^1])
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

proc explainWrapper(fn: NimNode): NimNode =
  let pgx_proc = newProc(ident("pgx_" & $fn.name), proc_type = nnkFuncDef)
  pgxFunctions[fn.name.repr] = fn.params
  pgx_proc.params[0] = ident("Datum")
  pgx_proc.pragma = newNimNode(nnkPragma).add(ident("pgv1")).add(ident("trusted"))

  var rbody = newTree(nnkStmtList)

  rbody = analyze_fn_body(fn)
  pgx_proc.body = rbody
  echo pgx_proc.repr
  
  result = pgx_proc
  fnIdx += 1

proc registerPGXEnum(obj: NimNode) = pgxEnums[obj[0][0].repr] = obj

macro pgx*(fn: untyped): untyped = 
  if fn.kind != nnkTypeDef:
    return explainWrapper(fn) 
  else:
    case fn[2].kind:
    of nnkEnumTy:
      registerPGXEnum(fn)
      return fn
    else:
      discard
  
