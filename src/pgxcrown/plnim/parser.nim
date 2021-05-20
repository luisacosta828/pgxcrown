import os
from osproc import execCmdEx
import strutils, strformat
import sequtils

proc check_nim_types(ttype: int):string {. inline .} =
    if ttype in [20,21,23]:
        result = "int"

proc positional_parameters(line: string): int {. inline .} = count(line,'$')

proc procedure_definition(procedure_name, nargs, argtypes, rettype, code: string): string {. inline .} =

    var import_segment = "\nimport strutils\n\n"
    var procedure = "proc " & procedure_name 
    let exported_signature = " {.exportc, dynlib.} "
    let space = "    "
    var ret = check_nim_types(parseInt(rettype))
    var loc = code
    var nloc:string
    var body:string

    if parseInt(nargs) == 0:
       procedure = procedure & "*(): " & ret  & exported_signature & " = \n"
    else:
       procedure = procedure & "*(symbols: seq[string]): " & ret  & exported_signature & " = \n"
    
    for line in splitLines(loc): 
        if line.contains("import"):
           import_segment = import_segment & line & "\n\n"
           nloc = nloc & loc.replace(line," ")

    if len(strip(nloc)) == 0:
        for line in splitLines(strip(loc)):    
            body = body & indent(line,4) & "\n"
    else:
        for line in splitLines(strip(nloc)):
            body = body & indent(line,4) & "\n"

    for c in 1..positional_parameters(body):
       for arg in argtypes.split(" "):
           if check_nim_types(parseInt(arg)) == "int":
              body = body.replace("$" & $c, "parseInt(symbols[" & $(c-1) & "])")

    import_segment & procedure & body & "\n"  

template build_nim_file*(source: tuple[name: string,src: string, nargs: string, argtypes: string, rettype: string] ):string =
    createDir("plnim/src")

    let filename = "plnim/src/" & source.name & ".nim"

    var final_code = procedure_definition(source.name, source.nargs, source.argtypes, source.rettype, source.src)    
    
    writeFile(filename,final_code)

    filename
