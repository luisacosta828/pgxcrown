# Windows may not always add all Postgres CLI tools to the PATH by default,
# if it can not find "pg_config" then can not find "libdir" nor "includedir".
# Windows full path is something like (int is semver):
# "C:\Program Files\PostgreSQL\17\bin\pg_config.exe"
import std/[os, osproc, strutils]


proc pgconfigFinder*(): string =
  result = "pg_config"
  when defined(windows):
    if not fileExists("pg_config.exe"):
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


proc pgLibFinder*(): string =
  let (output, exitCode) = execCmdEx(pgconfigFinder() & " --libdir")
  if exitCode == 0:
    result = output.strip
  when defined(windows):
    if not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\lib"""
      if dirExists(folder):
        for semver in 15 .. 25:
          if fileExists(folder & $semver & tail):
            result = folder & $semver & tail
            break
          if semver == 25:
            echo "WARNING: Can not find Postgres libdir"


proc pgIncludeFinder*(): string =
  let (output, exitCode) = execCmdEx(pgconfigFinder() & " --includedir")
  if exitCode == 0:
    result = output.strip
  when defined(windows):
    if not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\include"""
      if dirExists(folder):
        for semver in 15 .. 25:
          if fileExists(folder & $semver & tail):
            result = folder & $semver & tail
            break
          if semver == 25:
            echo "WARNING: Can not find Postgres includedir"
