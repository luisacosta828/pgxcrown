from strutils import split

const root = staticExec("pg_config --includedir").split("\n")[0]
const pg_config_error = "pg_config is not available"

when defined(windows):
    const libdir = staticExec("pg_config --libdir").split("\n")[0]
    if root == "":
        echo pg_config_error
    else:
        const server = " -I" & root & "/server"
        const win_32 = server & "/port/win32"
        const msvc = server & "/port/win32_msvc"
        const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64" 
        
        # didn't work on windows (wip)
        {.passC: "-D"&HAVE_LONG_LONG_INT_64 & win_32 & msvc & server & " -I"&root.}  
        {.passL: "-L"&libdir & " -lpostgres -lpq" .}        
    
else:
    if root == "":
      echo pg_config_error
    else:
      const pg_version:string = staticExec("""psql -V | awk '{ print "/"int($3)""} '""").split("\n")[0]
      const server = " -I" & root & pg_version & "/server"
      const internals = " -I" & root & "/internal"
      
      {.passC: server & internals & " -I" & root.}
