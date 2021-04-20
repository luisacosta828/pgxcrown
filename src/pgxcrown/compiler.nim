from strutils import split

const root = staticExec("pg_config --includedir").split("\n")[0]

when defined(windows):
    const libdir = staticExec("pg_config --libdir").split("\n")[0]
    if root == "":
        echo "pg_config no disponible."
    else:
        const server = " -I" & root & "/server"
        const win_32 = server & "/port/win32"
        const msvc = server & "/port/win32_msvc"
        const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64" 
        
        {.passC: "-D"&HAVE_LONG_LONG_INT_64 & win_32 & msvc & server & " -I"&root.}  
        {.passL: "-L"&libdir & " -lpostgres -lpq" .}        
    
else:
    when defined(python):
        const py_headers = "/usr/include/python2.7/"
        const py_lib = "python2.7"

        const libdir = staticExec("pg_config --pkglibdir").split("\n")[0]
        if root == "":
            echo "pg_config no disponible."
        else:
           #Se debe añadir postgresql-server-dev-XX
           const pg_version:string = staticExec("""psql -V | awk '{ print "/"int($3)"/server"} '""").split("\n")[0]
           #Se debe añadir la version de postgres antes del /server -> /include_path/version/server
           const server = " -I" & root & pg_version
           {.passC: server & " -I"&root & " -I"&py_headers & " -L/usr/lib/python2.7/ -l"&py_lib .}
    else:
        const libdir = staticExec("pg_config --pkglibdir").split("\n")[0]

        if root == "":
            echo "pg_config no disponible."
        else:
           #Se debe añadir postgresql-server-dev-XX
           const pg_version:string = staticExec("""psql -V | awk '{ print "/"int($3)"/server"} '""").split("\n")[0]
           #Se debe añadir la version de postgres antes del /server -> /include_path/version/server
           const server = " -I" & root & pg_version
           {.passC: server & " -I"&root.}
