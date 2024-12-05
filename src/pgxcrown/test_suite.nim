import std/[os, osproc, strutils, json]
from std/osproc import ProcessOption

proc dockerImage(version: int): string =
  var 
    command = "docker images postgres:" & $version  
  result = execCmdEx(command).output

proc dockerImageExists(version: int): bool = "postgres" in dockerImage(version)

proc dockerPull(version: int) =
  var
    command = "docker pull postgres:" & $version
  discard execShellCmd(command)

proc dockerStartPgInstance(version: int) =
  var 
    command = "docker run --name pgxtool_test_v" & $version & " -e POSTGRES_PASSWORD=postgres -d postgres:" & $version
  discard execCmdEx(command)
  discard execCmdEx("docker start pgxtool_test_v" & $version)

proc dockerRestartPgInstance(version: int) =
  var 
    command = "docker restart pgxtool_test_v" & $version
  discard execCmdEx(command)

proc dockerExecCmd(container, cmd: string): string =
  var command = "docker exec " & container & " bash -c " & quoteShell(cmd)
  execCmdEx(command).output
  
proc dockerCopyFile(container, source, dest: string) =
  var 
    command = "docker cp " & source & " " & container & ":" & dest
  discard execShellCmd(command)

proc serveTestEnv*(pgxtool_init_dir, pgxtool_config, project: string) =
  if len(findExe("docker")) > 0:
    if len(findExe("pg_config")) > 0:
      var 
        pgVersion = execCmdEx("""pg_config --version""").output.split(" ")[1].split(".")[0].parseInt
        
      if not dockerImageExists(pgVersion):
        dockerPull(pgVersion)
      
      var 
        file = parseJson(readFile(pgxtool_config))
        modules = file.getOrDefault("modules")

      if modules.hasKey(project):
        var test = modules.getOrDefault(project)
        if not test["test"].hasKey("version"):
          dockerStartPgInstance(pgVersion)
          test["test"] = %*{ "version": $pgVersion, "container_name": newJString("pgxtool_test_v" & $pgVersion) }
          modules.add(project, test)
          file["modules"] = modules
          writeFile(pgxtool_config, pretty(file))
        else:
          echo "Restarting docker instance..."
          dockerRestartPgInstance(pgVersion)
        
        var 
          path = pgxtool_init_dir / project / "src"
          container = "pgxtool_test_v" & $pgVersion
        echo "Copying sql file..."
        dockerCopyFile(container, path / project & ".sql", "/var/lib/postgresql/")
        var pkglibdir = dockerExecCmd(container, "pg_config --pkglibdir")
        echo "Copying library file..."
        dockerCopyFile(container, path / project, pkglibdir)

        echo dockerExecCmd(container, " psql -U postgres -f /var/lib/postgresql/" & project & ".sql")
        echo dockerExecCmd(container, " psql -U postgres -c 'select simple_add(41);'")
        


          







