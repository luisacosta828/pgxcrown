import std/[macros, strutils]


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
  of "int", "int32": "Int32"
  of "float", "float32": "Float4"
  of "float64": "Float8"
  else: "unknown"

template move_nim_params_as_locals =
  for i in 1..fnparams_len:
    var param = fn.params[i].repr.split(":")
    var pvar = param[0]
    var ptype = param[1].split(" ")[1]
    varSection.add(newIdentDefs(ident(pvar), ident(NimTypes(ptype))))

template init_locals_from_datum =
  for i in 1..fnparams_len:
    var param = fn.params[i].repr.split(":")
    var pvar = param[0]
    var ptype = param[1].split(" ")[1]
    var f = PgxToNim(ptype)
    if ptype == "string":
      var getValue = newCall(ident(f), [ident("argv"), newIntLitNode(i)])
      rbody.add newNimNode(nnkAsgn).add(ident(pvar), getValue)
    else:
      var getValue = newCall(ident(f), [newIntLitNode(i-1)])
      rbody.add newNimNode(nnkAsgn).add(ident(pvar), getValue)

template copy_fn_body =
  let body_lines = fn.body.len - 2
  for lines in 0..body_lines: rbody.add fn.body[lines]


proc explainWrapper(fn: NimNode): NimNode =

  let pgx_proc = newProc(ident("pgx_" & $fn.name))
  pgx_proc.params[0] = ident("Datum")

  pgx_proc.pragma = newNimNode(nnkPragma).add(ident("pgv1"))

  let rbody = newTree(nnkStmtList, pgx_proc.body)
  let fnparams_len = fn.params.len - 1
  var varSection = newNimNode(nnkVarSection)

  move_nim_params_as_locals

  var result_keyword = findChild(fn.body, it.kind == nnkAsgn and it[0].repr == "result")

  if result_keyword == nil:
    varSection.add(newIdentDefs(ident("myres"), ident(NimTypes(fn.params[0].repr))))

  rbody.add(varSection)

  init_locals_from_datum

  copy_fn_body

  if result_keyword == nil:
    rbody.add newNimNode(nnkAsgn).add(ident("myres"), fn.body[^1])

  var replywith = ident("return" & ReplyWithPgxTypes(fn.params[0].repr))
  if result_keyword == nil:
    rbody.add newCall(replywith, [ident("myres")])
  else:
    rbody.add newCall(replywith, [fn.body[^1][1]])


  pgx_proc.body = rbody

  when defined(debug): echo pgx_proc.repr
  result = pgx_proc

  echo result.repr


macro pgx*(fn: untyped): untyped = explainWrapper(fn)
