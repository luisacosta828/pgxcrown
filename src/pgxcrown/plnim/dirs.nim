import os
#import io

template build_nim_file*(filename, code: string) =
    let plnim_source_dir = "../../plnim/src/"
    let final_file = plnim_source_dir & filename & ".nim"
    createDir(plnim_source_dir) 
    writeFile(final_file,code)
