import std/[macros, strutils, macrocache]

const 
  pgxFunctions = CacheTable"pgxfn"
  pgxVarDecl   = CacheTable"pgxvar"

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
  of "string": "cstring"
  else: "unknown"


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
  of "string": "getCString"
  else: "unknown"


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

template move_nim_params_as_locals =
  for i in 1..fnparams_len:
    var param = fn.params[i].repr.split(":")
    var pvar = param[0]
    var ptype = param[1].split(" ")[1]
    var f = PgxToNim(ptype)
    var getValue = newCall(ident(f), [newIntLitNode(i-1)])
    varSection.add(newIdentDefs(ident(pvar), ident(NimTypes(ptype)), getValue))

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
proc analyze_node(code: NimNode): NimNode

proc check_infix_section(code: NimNode): NimNode =
  result = code
  result[1] = analyze_node(code[1])
  result[2] = analyze_node(code[2])
    
proc check_literal_values(code: NimNode): NimNode =
  var return_macro = "return" & ReplyLiteralsWithPgxTypes(code)
  call_return_macro(return_macro, code)

proc check_return_section(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  result.add analyze_node(code[0])

proc check_discard_section(code: NimNode): NimNode =
  result = check_return_section(code)

proc check_block_section(code: NimNode): NimNode = analyze_node(code)

proc analyze_node(code: NimNode): NimNode =
  result = newNimNode(code.kind)
  case code.kind:
  of nnkVarSection:
    result = check_var_section(code)
  of nnkAsgn:
    result = check_asgn_section(code)
  of nnkCall: 
    result = check_call_section(code)
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
  else:
    echo code.kind
    echo code.treerepr
    discard

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

  var fnparams_len = fn.params.len - 1
  move_nim_params_as_locals

  result.add varSection

  for item in fn.body: 
    result.add analyze_node(item)

proc explainWrapper(fn: NimNode): NimNode =
  let pgx_proc = newProc(ident("pgx_" & $fn.name), proc_type = nnkFuncDef)
  pgxFunctions[fn.name.repr] = fn.params
  pgx_proc.params[0] = ident("Datum")
  pgx_proc.pragma = newNimNode(nnkPragma).add(ident("pgv1"))

  var rbody = newTree(nnkStmtList)

  rbody = analyze_fn_body(fn)
  pgx_proc.body = rbody
  echo pgx_proc.repr
  
  result = pgx_proc


macro pgx*(fn: untyped): untyped = explainWrapper(fn)
