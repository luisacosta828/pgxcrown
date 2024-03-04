import macros
import tables
import strutils

proc NimTypes(dt: string): string =
  case dt:
    of "int", "int32": "cint"
    of "float", "float32": "cfloat"
    of "float64": "cdouble"
    of "int64": "clonglong"
    else: "unknown"

proc PgxToNim(dt: string): string =
  case dt:
    of "int", "int32": "getInt32"
    of "float", "float32": "getFloat4"
    of "float64": "getFloat8"
    else: "unknown"

proc explainWrapper(fn: NimNode):NimNode =

    let pgx_proc = newProc(ident("pgx_" & $fn.name))
    pgx_proc.params[0] = ident("Datum")

    pgx_proc.pragma = newNimNode(nnkPragma).add(ident("pgv1"))

    var ReplyWithPgxTypes = {"int":"Int32", "float": "Float4", "double": "Float8"}.toTable
    let rbody = newTree(nnkStmtList, pgx_proc.body)
    let fnparams_len = fn.params.len - 1
    var varSection = newNimNode(nnkVarSection)

    # Declaramos las variables desde las especificaciones del los parametros
    for i in 1..fnparams_len:
        var param = fn.params[i].repr.split(":")
        var pvar  =  param[0]
        var ptype =  param[1].split(" ")[1]
        varSection.add( newIdentDefs(ident(pvar), ident(NimTypes(ptype))))

    varSection.add( newIdentDefs(ident("myres"), ident(NimTypes(fn.params[0].repr))) )
    rbody.add(varSection)

    for i in 1..fnparams_len:
        var param = fn.params[i].repr.split(":")
        var pvar  =  param[0]
        var ptype =  param[1].split(" ")[1]
        var f = PgxToNim(ptype)
        if ptype == "string":
            var getValue = newCall(ident(f),[ident("argv"),newIntLitNode(i)])
            rbody.add newNimNode(nnkAsgn).add(ident(pvar),getValue)
        else:
            var getValue = newCall(ident(f),[newIntLitNode(i-1)])
            rbody.add newNimNode(nnkAsgn).add(ident(pvar),getValue)

    let body_lines = fn.body.len - 2
    for lines in 0..body_lines: rbody.add fn.body[lines]
    rbody.add newNimNode(nnkAsgn).add(ident("myres"),fn.body[^1])

    var replywith = ident("return" & ReplyWithPgxTypes[fn.params[0].repr])
    rbody.add newCall(replywith,[ident("myres")])

    pgx_proc.body = rbody

    #echo pgx_proc.repr
    result = pgx_proc

macro pgx*(fn: untyped): untyped = explainWrapper(fn)
