from std/strutils import split, strip, contains

proc safePgConfig(cmd: string, defaultVal: string): string =
  let raw = staticExec(cmd).strip
  if raw.len == 0 or "not found" in raw:
    return defaultVal
  return raw

proc discoverPgVersion(): string =
  let raw = safePgConfig("pg_config --version", "PostgreSQL 14")
  let parts = raw.split(" ")
  if parts.len >= 2:
    return parts[1].split(".")[0]
  else:
    return "14"

proc discoverIncludeDir(): string =
  when defined(windows):
    for semver in [17, 16, 15, 14, 13, 12]:
      let inc = "C:/Program Files/PostgreSQL/" & $semver & "/include"
      let chk = staticExec("if exist \"" & inc & "\\server\\postgres.h\" (echo found)").strip
      if "found" in chk:
        return inc
  let raw = safePgConfig("pg_config --includedir", "/usr/include/postgresql").split("\n")[0]
  when defined(windows):
    if "STRAWB" in raw.toUpperAscii or "not found" in raw:
      for semver in [17, 16, 15, 14, 13, 12]:
        return "C:/Program Files/PostgreSQL/" & $semver & "/include"
  return raw

proc discoverLibDir(): string =
  when defined(windows):
    for semver in [17, 16, 15, 14, 13, 12]:
      let lib = "C:/Program Files/PostgreSQL/" & $semver & "/lib"
      let chk = staticExec("if exist \"" & lib & "\" (echo found)").strip
      if "found" in chk:
        return lib
  let raw = safePgConfig("pg_config --libdir", "/usr/lib/postgresql").split("\n")[0]
  when defined(windows):
    if "STRAWB" in raw.toUpperAscii or "not found" in raw:
      for semver in [17, 16, 15, 14, 13, 12]:
        return "C:/Program Files/PostgreSQL/" & $semver & "/lib"
  return raw

const
  includeDir {.strdefine.} = discoverIncludeDir()
  libDir {.strdefine.} = discoverLibDir()
  pgVersion {.strdefine.} = discoverPgVersion()


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

  {.passC: server & internals & " -I" & includeDir & " -include postgres.h -include fmgr.h -include funcapi.h".}
else:
  quit "Unsupported operating system"
