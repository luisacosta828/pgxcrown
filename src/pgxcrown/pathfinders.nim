# Windows may not always add all Postgres CLI tools to the PATH by default,
# if it can not find "pg_config" then can not find "libdir" nor "includedir".
# Windows full path is something like (int is semver):
# "C:\Program Files\PostgreSQL\17\bin\pg_config.exe"
import std/[os, osproc, strutils]


proc pgconfigFinder*(): string =
  result = "pg_config"
  when defined(windows):
    if findExe("pg_config.exe").len > 0 or findExe("pg_config").len > 0:
      return "pg_config"
    const
      folder = """C:\Program Files\PostgreSQL\"""
      binary = """\bin\pg_config.exe"""
    if dirExists(folder):
      for semver in countdown(25, 12):
        let candidate = folder & $semver & binary
        if fileExists(candidate):
          return candidate

proc safeExecPgConfig(flag: string): (string, int) =
  let exe = pgconfigFinder()
  let cmd = quoteShell(exe) & " " & flag
  return execCmdEx(cmd)

proc pgLibFinder*(): string =
  let (output, exitCode) = safeExecPgConfig("--pkglibdir")
  if exitCode == 0 and output.strip.len > 0:
    result = output.strip
  when defined(windows):
    if result.len == 0 or not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\lib"""
      if dirExists(folder):
        for semver in countdown(25, 12):
          let candidate = folder & $semver & tail
          if dirExists(candidate):
            return candidate

proc pgIncludeFinder*(): string =
  let (output, exitCode) = safeExecPgConfig("--includedir")
  if exitCode == 0 and output.strip.len > 0:
    result = output.strip
  when defined(windows):
    if result.len == 0 or not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\include"""
      if dirExists(folder):
        for semver in countdown(25, 12):
          let candidate = folder & $semver & tail
          if dirExists(candidate):
            return candidate

proc pgIncludeServerFinder*(): string =
  let (output, exitCode) = safeExecPgConfig("--includedir-server")
  if exitCode == 0 and output.strip.len > 0:
    result = output.strip
  when defined(windows):
    if result.len == 0 or not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\include\server"""
      if dirExists(folder):
        for semver in countdown(25, 12):
          let candidate = folder & $semver & tail
          if dirExists(candidate):
            return candidate

proc pgShareDirFinder*(): string =
  let (output, exitCode) = safeExecPgConfig("--sharedir")
  if exitCode == 0 and output.strip.len > 0:
    result = output.strip
  when defined(windows):
    if result.len == 0 or not dirExists(result):
      const
        folder = """C:\Program Files\PostgreSQL\"""
        tail = """\share"""
      if dirExists(folder):
        for semver in countdown(25, 12):
          let candidate = folder & $semver & tail
          if dirExists(candidate):
            return candidate

proc pgExtensionDirFinder*(): string =
  let sharedir = pgShareDirFinder()
  if sharedir.len > 0:
    result = sharedir / "extension"


