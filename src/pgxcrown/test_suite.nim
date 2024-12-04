import std/[os, osproc, strutils]

proc dockerImage(version: int) =
  var command = ""

proc serveTestEnv*() =
  if len(findExe("docker")) > 0:
    if len(findExe("pg_config")) > 0:
      var 
        pgVersion = execCmdEx("""pg_config --version""").output.split(" ")[1].split(".")[0].parseInt






