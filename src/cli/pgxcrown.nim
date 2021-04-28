import os, osproc

import build_extension

var build_opt = paramStr(1)

if build_opt == "--build-extension":
     discard execCmd """ echo " """ & build_pg_function(paramStr(2)) & """ " > """ & nim_target_function & ".sql"
     echo "Created file: ",nim_target_function,".sql"
else:
   echo "error"
