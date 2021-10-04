import macros
import tables
import strutils

proc explainWrapper(fn: NimNode):NimNode =

    let pgx_proc = newProc(ident("pgx_" & $fn.name))
    pgx_proc.params[0] = ident("Datum")

    let pgx_pragmas = newNimNode(nnkPragma)
    pgx_pragmas.add(ident("pgv1"))
    pgx_proc.pragma = pgx_pragmas

    var NimTypes = {"int": "cint", "float": "cfloat", "double": "cdouble"}.toTable
    var PgxToNim = {"int":"getInt32", "float": "getFloat4", "double": "getFloat8"}.toTable
    var ReplyWithPgxTypes = {"int":"Int32", "float": "Float4", "double": "Float8"}.toTable
    let rbody = newTree(nnkStmtList, pgx_proc.body)
    let fnparams_len = fn.params.len - 1
    var varSection = newNimNode(nnkVarSection)

    # Declaramos las variables desde las especificaciones del los parametros
    for i in 1..fnparams_len:
        var param = fn.params[i].repr.split(":")
        var pvar  =  param[0]
        var ptype =  param[1].split(" ")[1]
        varSection.add( newIdentDefs(ident(pvar), ident(NimTypes[ptype])))

    varSection.add( newIdentDefs(ident("myres"), ident(NimTypes[fn.params[0].repr])) )
    rbody.add(varSection)

    for i in 1..fnparams_len:
        var param = fn.params[i].repr.split(":")
        var pvar  =  param[0]
        var ptype =  param[1].split(" ")[1]
        var f = PgxToNim[ptype]
        if ptype == "string":
            var getValue = newCall(ident(f),[ident("argv"),newIntLitNode(i)])
            rbody.add newNimNode(nnkAsgn).add(ident(pvar),getValue)
        else:
            var getValue = newCall(ident(f),[newIntLitNode(i-1)])
            rbody.add newNimNode(nnkAsgn).add(ident(pvar),getValue)

    # Copiamos las operaciones de la funcion original
    let body_lines = fn.body.len - 2
    for lines in 0..body_lines: rbody.add fn.body[lines]
    rbody.add newNimNode(nnkAsgn).add(ident("myres"),fn.body[^1])

    # Especificamos el return type para redis
    var replywith = ident("return" & ReplyWithPgxTypes[fn.params[0].repr])
    rbody.add newCall(replywith,[ident("myres")])

    pgx_proc.body = rbody

    echo pgx_proc.repr
    result = pgx_proc

macro pgx*(fn: untyped): untyped = explainWrapper(fn)
