import std/[os, strutils, macros]


const entrypoint {.strdefine.} = ""


template remove_and_install_dependencies(file: string, kind: string) =
  var source = parseStmt(readFile(file))
  del(source)

  var hook_module = 
    case kind:
    of "emit_log": "emit_hook"
    of "post_parse_analyze": "post_parse_hook"
    of "executor": "executor_hook"
    of "process_utility": "utility_hook"
    else: ""

  var res {.inject.} = newNimNode(nnkStmtList)
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown")
  res.add newNimNode(nnkImportStmt).add ident("pgxcrown/hooks/" & hook_module)
  res.add ident("PG_MODULE_MAGIC")
  res.add ident("ActivateHooks")


template init_hook(file: string, kind: string, params: seq[NimNode]) =
  remove_and_install_dependencies(file, kind)

  var
    hook_type = kind & "_hook_type"
    original_hook_sym = ident(kind & "_hook")
    user_hook_sym = ident("prev_" & kind)
    custom_proc_ident = ident("custom_proc")
    original_hook_var = original_hook_sym.repr & " {. original_hook .}"
    user_hook_var = user_hook_sym.repr & " {. user_hook .}"

  res.add newNimNode(nnkVarSection).add newIdentDefs(ident(original_hook_var), ident(hook_type))
  res.add newNimNode(nnkVarSection).add newIdentDefs(ident(user_hook_var), ident(hook_type))

  var exprc, exprc2, exprc3 = newNimNode(nnkExprColonExpr)
  exprc.add(ident("exportc"))
  exprc2.add(ident("exportc"))
  exprc.add(newStrLitNode("_PG_init"))
  exprc2.add(newStrLitNode("_PG_fini"))

  var
    pg_init = newProc(ident("pg_init"), pragmas = newNimNode(nnkPragma))
    pg_fini = newProc(ident("pg_fini"), pragmas = newNimNode(nnkPragma))
    custom_proc = newProc(custom_proc_ident, pragmas = newNimNode(nnkPragma))

  custom_proc.params.add params
  custom_proc.pragma = newNimNode(nnkPragma).add(ident("cdecl"))
  custom_proc.body.add quote do:
    discard

  pg_init.pragma = newNimNode(nnkPragma).add(exprc)
  pg_init.pragma.add newNimNode(nnkPragma).add(ident("pginitexport"))
  pg_init.body.add quote do:
    `user_hook_sym.repr` = `original_hook_sym.repr`
    `original_hook_sym.repr` = `custom_proc_ident.repr`

  pg_fini.pragma = newNimNode(nnkPragma).add(exprc2)
  pg_fini.body.add quote do:
    `original_hook_sym.repr` = `user_hook_sym.repr`

  res.add custom_proc
  res.add pg_init
  res.add pg_fini

  writeFile(file.replace("tmp_", ""), res.repr)


macro build_hook*() =
  var (dir, _, _) = splitFile(entrypoint)
  var selectedHook = dir.parentDir.lastPathPart

  if selectedHook == "executor":
    var source = parseStmt(readFile(entrypoint))
    del(source)
    let code = """
import pgxcrown
import pgxcrown/hooks/executor_hook
import pgxcrown/hooks/registry

PG_MODULE_MAGIC
ActivateHooks

proc onExecutorStart(info: ExecutorQueryInfo, eflags: cint) =
  discard

proc onExecutorRun(info: ExecutorQueryInfo, direction: ScanDirection, count: uint64, executeOnce: bool) =
  discard

proc onExecutorFinish(info: ExecutorQueryInfo) =
  discard

proc onExecutorEnd(info: ExecutorQueryInfo) =
  discard

proc pg_init() {.exportc: "_PG_init", pginitexport.} =
  registerExecutorStartHook(onExecutorStart)
  registerExecutorRunHook(onExecutorRun)
  registerExecutorFinishHook(onExecutorFinish)
  registerExecutorEndHook(onExecutorEnd)

proc pg_fini() {.exportc: "_PG_fini".} =
  uninstallExecutorHooks()
"""
    writeFile(entrypoint.replace("tmp_", ""), code)
  elif selectedHook == "process_utility":
    var source = parseStmt(readFile(entrypoint))
    del(source)
    let code = """
import pgxcrown
import pgxcrown/hooks/utility_hook
import pgxcrown/hooks/registry

PG_MODULE_MAGIC
ActivateHooks

proc onProcessUtility(info: UtilityStmtInfo) =
  discard

proc pg_init() {.exportc: "_PG_init", pginitexport.} =
  registerProcessUtilityHook(onProcessUtility)

proc pg_fini() {.exportc: "_PG_fini".} =
  uninstallProcessUtilityHook()
"""
    writeFile(entrypoint.replace("tmp_", ""), code)
  else:
    var params: seq[NimNode] = case selectedHook
      of "emit_log": @[newIdentDefs(ident("edata"), newNimNode(nnkPtrTy).add(ident("ErrorData")))]
      of "post_parse_analyze": @[
        newIdentDefs(ident("pstate"), newNimNode(nnkPtrTy).add(ident("ParseState"))),
        newIdentDefs(ident("query"), newNimNode(nnkPtrTy).add(ident("Query"))),
        newIdentDefs(ident("jstate"), ident("JumbleStatePtr"))
      ]
      else: @[]

    init_hook(entrypoint, selectedHook, params)


build_hook()
