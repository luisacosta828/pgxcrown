from std/strutils import split


const
  includeDir {.strdefine.} = staticExec("pg_config --includedir").split("\n")[0]
  libDir {.strdefine.} = staticExec("pg_config --libdir").split("\n")[0]
  pgVersion {.strdefine.} = staticExec("""pg_config --version""").split(" ")[1].split(".")[0]  # pg_config --version ???


if includeDir.len == 0:
  echo "Postgres includedir not found, use -d:includeDir='full/path/to/postgres/include/'"
if libDir.len == 0:
  echo "Postgres libDir not found, use -d:libDir='full/path/to/postgres/lib/'"
if pgVersion.len == 0:
  echo "Postgres pgVersion not found, use -d:pgVersion='17.0'"


when defined(windows):
  const server = " -I" & includeDir & "/server"
  const win_32 = server & "/port/win32"
  const msvc = server & "/port/win32_msvc"
  const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64"

  {.passC: "-D" & HAVE_LONG_LONG_INT_64 & " -DWIN32 -DWINDOWS -D__WINDOWS__ -D__WIN32__ -D_CRT_SECURE_NO_DEPRECATE -D_CRT_NONSTDC_NO_DEPRECATE" & win_32 & msvc & server & " -I" & includeDir.}

elif defined(linux):
  const server = " -I" & includeDir & "/" & pgVersion & "/server"
  const internals = " -I" & includeDir & "/" & pgVersion & "/internal"

  {.passC: server & internals & " -I" & includeDir.}
else:
  quit "Unsupported operating system"
