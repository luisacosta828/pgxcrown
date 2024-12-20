import std/[macros, strutils, macrocache]

const 
  pgxFunctions = CacheTable"pgxfn"
  pgxVarDecl   = CacheTable"pgxvar"

template NimTypes(dt: string): string =
  case dt
  of "int", "int32": "cint"
  of "float", "float32": "cfloat"
  of "float64": "cdouble"
  of "int64": "clonglong"
  else: "unknown"


template PgxToNim(dt: string): string =
  case dt
  of "int", "int32": "getInt32"
  of "float", "float32": "getFloat4"
  of "float64": "getFloat8"
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
    if ptype != "string":
      var getValue = newCall(ident(f), [newIntLitNode(i-1)])
      varSection.add(newIdentDefs(ident(pvar), ident(NimTypes(ptype)), getValue))

template copy_fn_body =
  let body_lines = fn.body.len - 2
  for lines in 0..body_lines:
    rbody.add fn.body[lines]


template call_return_macro(fn_call: string, code: NimNode): NimNode =
  newCall(return_macro, [code])

proc check_infix_section(code: NimNode, fn_return_type: string): NimNode
proc check_literal_values(code: NimNode): NimNode
proc check_return_section(code: NimNode, fn: NimNode): NimNode
proc check_call_section(code: NimNode): NimNode
proc check_var_section(code: NimNode, fnparams_len: int, fn: NimNode, varSection: NimNode)
proc check_if_section(code: NimNode, fn: NimNode, body: NimNode) 
proc check_asgn_section(code: NimNode, fn: NimNode): NimNode

proc check_infix_section(code: NimNode, fn_return_type: string): NimNode =
  var return_macro = "return" & ReplyWithPgxTypes(NimTypes(fn_return_type))
  call_return_macro(return_macro, code)
    
proc check_literal_values(code: NimNode): NimNode =
  var return_macro = "return" & ReplyLiteralsWithPgxTypes(code)
  call_return_macro(return_macro, code)

proc check_return_section(code: NimNode, fn: NimNode): NimNode =
  var return_macro = "return" & ReplyWithPgxTypes(fn.params[0].repr)
  call_return_macro(return_macro, code[0])

proc check_call_section(code: NimNode):NimNode =
  var fn_name = code[0].repr
  if fn_name in pgxFunctions:
    var
      idx = 0
      pgx_args:seq[NimNode]
    for props in code:
      if idx == 0:
        pgx_args.add ident("pgx_" & props.repr)
      else:
        var dt = pgxFunctions[fn_name][idx][1].repr
        pgx_args.add newCall(ident(ReplyWithPgxTypes(NimTypes(dt)) & "GetDatum"), [props])
      inc(idx) 
    result = newCall(ident("DirectFunctionCall" & $(pgx_args.len - 1)), pgx_args)
  else:
    result = code
    
proc check_var_section(code: NimNode, fnparams_len: int, fn: NimNode, varSection: NimNode) =
  if code[0][2].kind == nnkCall:
    var fn_name = code[0][2][0].repr
    if fn_name in pgxFunctions:
      var 
        returnType  = NimTypes(pgxFunctions[fn_name][0].repr)
        pgx_fn_call = check_call_section(code[0][2]) 
        replywith = ident("DatumGet" & ReplyWithPgxTypes(pgxFunctions[fn_name][0].repr))
      varSection.add(newIdentDefs(code[0][0], ident(returnType), newCall(replywith, [pgx_fn_call]) ))
      var last_var = varSection[^1]
      pgxVarDecl[last_var[0].repr] = last_var[1]
    else:
      varSection.add code[0]
  else:
    varSection.add code[0]

proc check_if_section(code: NimNode, fn: NimNode, body: NimNode) = 
  var branchSection = newNimNode(nnkIfStmt)
  for stmt in code:
    var 
      new_node = newNimNode(stmt.kind)
      new_stmt_list = newNimNode(nnkStmtList)
      branch_code = findChild(stmt, it.kind == nnkStmtList)
    #copy condition statement
    if stmt.kind != nnkElse:
      new_node.add stmt[0]
    new_node.add new_stmt_list
    for bcode in branch_code:
      case bcode.kind:
      of nnkIfStmt:
        check_if_section(bcode, fn, new_stmt_list) 
      of nnkReturnStmt:
        var res = check_return_section(bcode, fn)
        new_stmt_list.add res
      of nnkVarSection:
        var varSection = newNimNode(nnkVarSection)
        check_var_section(bcode, fn.params.len - 1, fn, varSection)
        new_stmt_list.add varSection
      else:
        echo code.kind
    branchSection.add new_node 
  body.add branchSection
  

proc check_asgn_section(code: NimNode, fn: NimNode): NimNode =
  var is_result_asgn = code[0].repr == "result"

  case code[1].kind:
  of nnkCall:
    var 
      fn_call = check_call_section(code[1])
      fn_name = code[1][0].repr
    if fn_name in pgxFunctions:
      var 
        returnType  = NimTypes(pgxFunctions[fn_name][0].repr) 
        replywith = ident("DatumGet" & ReplyWithPgxTypes(pgxFunctions[fn_name][0].repr))
      
      code[1] = 
        if is_result_asgn:
          fn_call
        else:
          newCall(replywith, [fn_call])    
    else:
      if is_result_asgn:
        var cast_fn = ReplyWithPgxTypes(fn.params[0].repr) & "GetDatum"
        code[1] = newCall(cast_fn, [code[1]])
      else:  
        var cast_fn = newNimNode(nnkCast)
        cast_fn.add pgxVarDecl[code[0].repr]
        cast_fn.add fn_call
        code[1] = cast_fn
    result = code
  else: discard


proc analyze_fn_body(fn: NimNode): NimNode =
  result = newTree(nnkStmtList)
  var varSection = newNimNode(nnkVarSection)

  var fnparams_len = fn.params.len - 1
  move_nim_params_as_locals

  result.add varSection

  for item in fn.body:
    case item.kind:
    of nnkVarSection, nnkLetSection:
      check_var_section(item, fn.params.len - 1, fn, varSection)
    of nnkAsgn:
      result.add check_asgn_section(item, fn)
    of nnkReturnStmt:
      result.add check_return_section(item, fn) 
    of nnkIfStmt:
      check_if_section(item, fn, result)
    of nnkCharLit .. nnkFloat64Lit: 
      result.add check_literal_values(item)
    of nnkInfix:
      result.add check_infix_section(item, fn.params[0].repr)
    of nnkCall:
      result.add check_call_section(item)
    else:
      echo item.kind

      discard
  
  #var result_keyword = findChild(fn.body, it.kind == nnkAsgn and it[0].repr == "result")

  #if result_keyword == nil:
  #  varSection.add(newIdentDefs(ident("myres"), ident(NimTypes(fn.params[0].repr))))


proc explainWrapper(fn: NimNode): NimNode =

  let pgx_proc = newProc(ident("pgx_" & $fn.name), proc_type = nnkFuncDef)
  pgxFunctions[fn.name.repr] = fn.params
  pgx_proc.params[0] = ident("Datum")

  pgx_proc.pragma = newNimNode(nnkPragma).add(ident("pgv1"))

  var rbody = newTree(nnkStmtList)

  echo fn.name.repr
  rbody = analyze_fn_body(fn)
  pgx_proc.body = rbody
  echo pgx_proc.repr
  #[
    
  if result_keyword == nil:
    rbody.add newNimNode(nnkAsgn).add(ident("myres"), fn.body[^1])

  var replywith = ident("return" & ReplyWithPgxTypes(fn.params[0].repr))
  if result_keyword == nil:
    rbody.add newCall(replywith, [ident("myres")])
  else:
    rbody.add newCall(replywith, [fn.body[^1][1]])

  #echo rbody.treerepr
  pgx_proc.body = rbody

  when defined(debug): echo pgx_proc.repr
  result = pgx_proc
  ]#
  #echo pgx_proc.repr
  
  result = pgx_proc


macro pgx*(fn: untyped): untyped = explainWrapper(fn)
