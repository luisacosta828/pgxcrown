import os
from osproc import execCmdEx

template build_nim_file*(filename, code: string):string =
    let plnim_source_dir = "../../plnim/src/"
    let final_file = plnim_source_dir & filename & ".nim"
    createDir(plnim_source_dir) 
    writeFile(final_file,code)
    final_file

template compile_code*(file: string) = 
    echo execCmdEx "nim c -d:release --hints:on --opt:size --app:lib " & file

