import std/[os, staticos]
from std/strutils import split


proc pgconfigFinder*(): string =
  ## Find "pg_config" CLI tool path at run-time.
  # Windows may not add all CLI tools to PATH by default.
  # Windows full path is something like (int is semver):
  # "C:\Program Files\PostgreSQL\17\bin\pg_config.exe"
  result = "pg_config"
  when defined(windows):
    const
      folder = """C:\Program Files\PostgreSQL\"""
      binary = """\bin\pg_config.exe"""
    if dirExists(folder):
      for semver in 15 .. 25:
        if fileExists(folder & $semver & binary):
          result = folder & $semver & binary
          break
        if semver == 25:
          echo "WARNING: Can not find pg_config.exe"


proc staticPgconfigFinder*(): string =
  ## Find "pg_config" CLI tool path at compile-time.
  result = "pg_config"
  when defined(windows):
    const
      folder = """C:\Program Files\PostgreSQL\"""
      binary = """\bin\pg_config.exe"""
    if staticDirExists(folder):
      for semver in 15 .. 25:
        if staticFileExists(folder & $semver & binary):
          result = folder & $semver & binary
          break
        if semver == 25:
          echo "WARNING: Can not find pg_config.exe"


const
  pg_config = staticPgconfigFinder()
  root = staticExec(pg_config & " --includedir").split("\n")[0]
  pg_config_error = "pg_config is not available"


when defined(windows):
    const libdir = staticExec(pg_config & " --libdir").split("\n")[0]
    if root == "":
        echo pg_config_error
    else:
        const server = " -I" & root & "/server"
        const win_32 = server & "/port/win32"
        const msvc = server & "/port/win32_msvc"
        const HAVE_LONG_LONG_INT_64 = "HAVE_LONG_LONG_INT_64"

        # didn't work on windows (wip)
        {.passC: "-D" & HAVE_LONG_LONG_INT_64 & win_32 & msvc & server & " -I" & root.}
        {.passL: "-L" & libdir & " -lpostgres -lpq" .}
elif defined(linux):
    if root == "":
      echo pg_config_error
    else:
      const pg_version: string = staticExec("""psql -V | awk '{ print "/"int($3)""} '""").split("\n")[0]
      const server = " -I" & root & pg_version & "/server"
      const internals = " -I" & root & "/internal"

      {.passC: server & internals & " -I" & root.}
else:
  quit "Unsupported operating system"
