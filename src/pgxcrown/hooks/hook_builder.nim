import std/[os, strutils, macros]

const entrypoint {. strdefine .} = ""

template init_emit_hook(file: string) =
  var source = parseStmt(readFile(file))
  del(source)

  var res = newNimNode(nnkStmtList)
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  res.add ident("PG_MODULE_MAGIC")
  res.add ident("ActivateHooks")
  
  res.add newNimNode(nnkVarSection).add newIdentDefs(ident("""emit_log_hook {. hook_symbol .}"""), ident("emit_log_hook_type"), newNilLit())
  res.add newNimNode(nnkVarSection).add newIdentDefs(ident("""prev_emit_log {. static_hook .}"""), ident("emit_log_hook_type"), newNilLit())
  var 
    pg_init = newProc(ident("pg_init"), pragmas = newNimNode(nnkPragma))

  var body = quote do: 
    prev_emit_log = emit_log_hook
    emit_log_hook = custom_emit_log

  var params = [newIdentDefs(ident("edata"),newNimNode(nnkPtrTy).add(ident("ErrorData"))) ]
  var custom_emit_log = newProc(ident("custom_emit_log"))
  custom_emit_log.params.add params
  custom_emit_log.pragma = newNimNode(nnkPragma).add(ident("cdecl"))
  custom_emit_log.body.add quote do:
    discard

  res.add custom_emit_log

  pg_init.body.add body
  var exprc, exprc2 = newNimNode(nnkExprColonExpr)
  exprc.add(ident("exportc"))
  exprc2.add(ident("exportc"))
  exprc.add(newStrLitNode("_PG_init"))
  exprc2.add(newStrLitNode("_PG_fini"))
  pg_init.pragma = newNimNode(nnkPragma).add(exprc)

  res.add pg_init

  var pg_fini = newProc(ident("pg_fini"), pragmas = newNimNode(nnkPragma))
  var body2 = quote do:
    emit_log_hook = prev_emit_log

  pg_fini.body.add body2
  pg_fini.pragma = newNimNode(nnkPragma).add(exprc2)

  res.add pg_fini
  writeFile(file.replace("tmp_",""),res.repr)

template emit_hook(file: string) =
  init_emit_hook(file)


macro build_hook*() =
  var (dir, _, _) = splitFile(entrypoint)
  var selectedHook     = dir.split("/")[0]

  case selectedHook:
    of "emit_hook": emit_hook(entrypoint)
    else: discard


build_hook()
