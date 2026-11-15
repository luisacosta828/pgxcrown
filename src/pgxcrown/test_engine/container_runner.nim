import std/[os, strutils, times]
import oci_driver

type
  PgContainerContext* = object
    docker*: DockerDriver
    containerName*: string
    pgVersion*: int
    pkglibdir*: string
    extensiondir*: string

proc waitForPgReady*(docker: DockerDriver, containerName: string, timeoutSec: int = 35): bool =
  let startTime = epochTime()
  while epochTime() - startTime < timeoutSec.float:
    let (output, exitCode) = docker.execInContainer(containerName, "pg_isready -U postgres")
    if exitCode == 0 and "accepting connections" in output:
      return true
    sleep(200)
  return false

proc inspectContainerPaths*(docker: DockerDriver, containerName: string): (string, string) =
  let (libOut, libCode) = docker.execInContainer(containerName, "pg_config --pkglibdir")
  let (shareOut, shareCode) = docker.execInContainer(containerName, "pg_config --sharedir")
  
  var pkglibdir = if libCode == 0 and libOut.strip.len > 0: libOut.strip else: "/usr/lib/postgresql/lib"
  var sharedir = if shareCode == 0 and shareOut.strip.len > 0: shareOut.strip else: "/usr/share/postgresql"
  var extensiondir = sharedir / "extension"

  return (pkglibdir, extensiondir)

proc setupPgSandbox*(docker: DockerDriver, containerName: string, pgVersion: int): PgContainerContext =
  if not docker.ensureImage(pgVersion):
    quit("❌ Failed to ensure image for PostgreSQL " & $pgVersion)

  if not docker.startPgContainer(containerName, pgVersion):
    quit("❌ Failed to start container '" & containerName & "'")

  if not docker.waitForPgReady(containerName, timeoutSec = 35):
    let (logs, _) = docker.execCmdRaw("logs --tail 30 " & quoteShell(containerName))
    echo "❌ PostgreSQL did not become ready in container '", containerName, "'. Recent logs:\n", logs
    discard docker.removeContainer(containerName)
    quit("❌ Aborting test run due to container initialization timeout.")

  let (pkglibdir, extensiondir) = docker.inspectContainerPaths(containerName)
  # Ensure extension directory exists
  discard docker.execInContainer(containerName, "mkdir -p " & quoteShell(extensiondir))

  return PgContainerContext(
    docker: docker,
    containerName: containerName,
    pgVersion: pgVersion,
    pkglibdir: pkglibdir,
    extensiondir: extensiondir
  )

proc buildAndInstallProjectInContainer*(
  ctx: PgContainerContext,
  projectDir: string,
  projectName: string,
  isHook: bool = false,
  debug: bool = false,
  verbose: bool = false
): bool =
  ## Copies the project source into the pgxcrown container, compiles natively against the container's
  ## PostgreSQL headers, and installs the resulting extension into pkglibdir/extensiondir.
  let containerProjectDir = "/workspace/pgx/" & projectName
  let containerSrcDir = containerProjectDir / "src"

  let prepScript =
    "if [ ! -f /workspace/pgx/config.json ]; then pgxtool init >/dev/null; fi && " &
    "rm -rf " & quoteShell(containerProjectDir) & " && " &
    "mkdir -p " & quoteShell(containerProjectDir)
  let (prepOut, prepCode) = ctx.docker.execInContainer(
    ctx.containerName,
    "bash -lc " & quoteShell(prepScript)
  )
  if prepCode != 0:
    echo "❌ Failed to prepare container workspace for '", projectName, "':\n", prepOut
    return false

  let normalizedHostDir = projectDir.strip(leading = false, trailing = true, chars = {'/', '\\'})
  if not ctx.docker.copyIntoContainer(ctx.containerName, normalizedHostDir & "/.", containerProjectDir & "/"):
    return false

  let cleanArtifacts =
    "rm -rf " & quoteShell(containerProjectDir / ".pgx_build") & " " &
    quoteShell(containerSrcDir / projectName) & " " &
    quoteShell(containerSrcDir / (projectName & ".so")) & " " &
    quoteShell(containerSrcDir / ("lib" & projectName & ".so")) & " " &
    quoteShell(containerSrcDir / (projectName & ".control")) & " " &
    quoteShell(containerSrcDir / (projectName & ".sql")) & " " &
    quoteShell(containerSrcDir / (projectName & "--0.0.1.sql")) & " " &
    quoteShell(containerSrcDir / "install.sh") & " " &
    quoteShell(containerSrcDir) & "/tmp_*"

  var buildCmd = "pgxtool build-extension " & quoteShell(projectName) & " --force"
  if debug: buildCmd.add " --debug"
  if verbose: buildCmd.add " --verbose"

  let installCmd =
    if isHook:
      "mkdir -p " & quoteShell(ctx.pkglibdir) & " && " &
      "if [ -f " & quoteShell(containerSrcDir / (projectName & ".so")) & " ]; then " &
      "cp -f " & quoteShell(containerSrcDir / (projectName & ".so")) & " " & quoteShell(ctx.pkglibdir / (projectName & ".so")) & "; " &
      "elif [ -f " & quoteShell(containerSrcDir / projectName) & " ]; then " &
      "cp -f " & quoteShell(containerSrcDir / projectName) & " " & quoteShell(ctx.pkglibdir / (projectName & ".so")) & "; fi"
    else:
      quoteShell(containerSrcDir / "install.sh")

  let buildScript =
    "set -e && " & cleanArtifacts & " && " & buildCmd & " && " & installCmd

  let (buildOut, buildCode) = ctx.docker.execInContainer(
    ctx.containerName,
    "bash -lc " & quoteShell(buildScript)
  )
  if buildCode != 0:
    echo "❌ Failed to compile/install '", projectName, "' inside PostgreSQL ", ctx.pgVersion, " container:\n", buildOut
    return false

  if verbose or debug:
    echo buildOut
  return true

proc injectExtensionFiles*(ctx: PgContainerContext, projectDir: string, projectName: string): bool =
  let srcDir = projectDir / "src"
  var soFile = srcDir / (projectName & ".so")
  if not fileExists(soFile):
    let plainFile = srcDir / projectName
    let libSo = srcDir / ("lib" & projectName & ".so")
    if fileExists(plainFile):
      soFile = plainFile
    elif fileExists(libSo):
      soFile = libSo

  if not fileExists(soFile):
    echo "❌ Binary shared library not found for extension '", projectName, "' in ", srcDir
    return false

  # Copy .so to pkglibdir / (projectName & ".so")
  let destSo = ctx.pkglibdir / (projectName & ".so")
  if not ctx.docker.copyIntoContainer(ctx.containerName, soFile, destSo):
    return false

  # Copy .control and .sql files to extensiondir
  for kind, path in walkDir(srcDir):
    if kind == pcFile:
      let fn = extractFilename(path)
      if fn.endsWith(".control") or fn.endsWith(".sql"):
        let dest = ctx.extensiondir / fn
        if not ctx.docker.copyIntoContainer(ctx.containerName, path, dest):
          return false

  return true

proc createCleanDatabase*(ctx: PgContainerContext, dbName: string, extensionName: string, isHook: bool = false): bool =
  # Drop old DB if exists
  discard ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d postgres -c \"DROP DATABASE IF EXISTS \\\"" & dbName & "\\\" WITH (FORCE);\"")
  
  # Create fresh DB
  let (createOut, createCode) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d postgres -c \"CREATE DATABASE \\\"" & dbName & "\\\";\"")
  if createCode != 0:
    echo "❌ Failed to create database '", dbName, "': ", createOut
    return false

  if isHook:
    let escapedHook = extensionName.replace("'", "''")
    # Execute ALTER SYSTEM and pg_reload_conf in separate -c calls; psql wraps multi-statement -c in a transaction block.
    let alterSql = "ALTER SYSTEM SET session_preload_libraries = '" & escapedHook & "';"
    let (hookOut, hookCode) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d postgres -c " & quoteShell(alterSql))
    if hookCode != 0:
      echo "❌ Failed to configure session_preload_libraries for hook '", extensionName, "': ", hookOut
      return false
    let (reloadOut, reloadCode) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d postgres -c \"SELECT pg_reload_conf();\"")
    if reloadCode != 0:
      echo "❌ Failed to reload PostgreSQL configuration for hook '", extensionName, "': ", reloadOut
      return false
    let (verifyOut, verifyCode) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d " & quoteShell(dbName) & " -c \"LOAD '" & escapedHook & "';\"")
    if verifyCode != 0:
      echo "❌ Failed to load hook shared library '", extensionName, "' in database '", dbName, "': ", verifyOut
      return false
  else:
    # Install extension in new DB
    let (extOut, extCode) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d " & quoteShell(dbName) & " -c \"CREATE EXTENSION \\\"" & extensionName & "\\\" CASCADE;\"")
    if extCode != 0:
      echo "❌ Failed to run 'CREATE EXTENSION ", extensionName, "' in test database '", dbName, "': ", extOut
      return false

  return true

proc executeSqlInContainer*(ctx: PgContainerContext, dbName: string, localSqlPath: string): (string, int) =
  let containerSqlPath = "/tmp/current_test.sql"
  if not ctx.docker.copyIntoContainer(ctx.containerName, localSqlPath, containerSqlPath):
    return ("Failed to copy test script into container", 1)

  let psqlCmd = "psql -U postgres -d " & quoteShell(dbName) & " -X -a -P pager=off -v ON_ERROR_STOP=0 -f " & quoteShell(containerSqlPath)
  let (output, exitCode) = ctx.docker.execInContainer(ctx.containerName, psqlCmd)
  return (output, exitCode)

proc dropDatabase*(ctx: PgContainerContext, dbName: string): bool =
  let (_, code) = ctx.docker.execInContainer(ctx.containerName, "psql -U postgres -d postgres -c \"DROP DATABASE IF EXISTS \\\"" & dbName & "\\\" WITH (FORCE);\"")
  return code == 0

proc cleanupSandbox*(ctx: PgContainerContext) =
  discard ctx.docker.removeContainer(ctx.containerName)
