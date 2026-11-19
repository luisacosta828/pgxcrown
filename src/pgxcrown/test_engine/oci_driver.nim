import std/[os, osproc, strutils]

const
  SupportedPgVersions* = [14, 15, 16, 17]
  LatestPgVersion* = SupportedPgVersions[^1] # 17 (latest)
  DefaultLocalImageRepo* = "pgxcrown"
  DefaultRegistryImageRepo* = "ghcr.io/luisacosta828/pgxcrown"
  CompileTimeRepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir

type
  DockerDriver* = object
    binaryPath*: string

proc parsePgVersion*(verStr: string): int =
  let s = verStr.toLowerAscii.strip
  if s == "latest":
    return LatestPgVersion
  try:
    let v = parseInt(s)
    if v in SupportedPgVersions:
      return v
    else:
      return -1
  except ValueError:
    return -1

proc detectHostPgVersion*(): int =
  let p = findExe("pg_config")
  if p.len > 0:
    let (output, code) = execCmdEx(quoteShell(p) & " --version")
    if code == 0:
      for part in output.splitWhitespace():
        let dotParts = part.split('.')
        if dotParts.len > 0:
          try:
            let v = parseInt(dotParts[0])
            if v in SupportedPgVersions:
              return v
          except ValueError:
            discard
  return LatestPgVersion

proc isInsideContainer*(): bool =
  ## Returns true when running inside a Linux container.
  fileExists("/.dockerenv") or getEnv("container", "").len > 0

proc tryDetectDockerEngine*(driver: var DockerDriver): bool =
  ## Attempts to locate a usable Docker CLI and reachable daemon without aborting.
  let dockerExe = findExe("docker")
  if dockerExe.len == 0:
    return false
  let (_, code) = execCmdEx(quoteShell(dockerExe) & " ps")
  if code != 0:
    return false
  driver = DockerDriver(binaryPath: dockerExe)
  return true

proc detectDockerEngine*(): DockerDriver =
  var driver: DockerDriver
  if tryDetectDockerEngine(driver):
    return driver
  let dockerExe = findExe("docker")
  if dockerExe.len == 0:
    quit("❌ [DOCKER NOT FOUND] Docker is required to run isolated container tests.\nPlease install Docker or start the Docker service.")
  quit("❌ [DOCKER ERROR] Docker daemon is not running or current user lacks permissions.\nPlease start Docker (e.g. 'sudo systemctl start docker' or check user groups).")

proc execCmdRaw*(docker: DockerDriver, cmdArgs: string): (string, int) =
  let fullCmd = quoteShell(docker.binaryPath) & " " & cmdArgs
  return execCmdEx(fullCmd)

proc execCmdLive*(docker: DockerDriver, cmdArgs: string): int =
  let fullCmd = quoteShell(docker.binaryPath) & " " & cmdArgs
  return execCmd(fullCmd)

proc getPgxcrownImageRepo*(): string {.inline.} =
  let custom = getEnv("PGXCROWN_IMAGE", "").strip()
  if custom.len > 0: custom else: DefaultLocalImageRepo

proc getCanonicalImageTag*(pgVersion: int): string {.inline.} =
  getPgxcrownImageRepo() & ":" & $pgVersion

proc isImagePresent*(docker: DockerDriver, imageTag: string): bool =
  let (output, exitCode) = docker.execCmdRaw("images -q " & quoteShell(imageTag))
  return exitCode == 0 and output.strip.len > 0

proc isValidPgxcrownRepoDir(repoDir: string): bool {.inline.} =
  repoDir.len > 0 and
    fileExists(repoDir / "docker" / "Dockerfile") and
    fileExists(repoDir / "pgxcrown.nimble")

proc walkUpForDockerDir(startDir: string): string =
  var cur = startDir
  while cur.len > 0:
    if isValidPgxcrownRepoDir(cur):
      return cur / "docker"
    let parent = cur.parentDir
    if parent == cur:
      break
    cur = parent
  return ""

proc findPgxcrownDockerDir*(): string =
  ## Locates pgxcrown's docker/ directory from env, cwd, executable location, or build root.
  let envDockerDir = getEnv("PGXCROWN_DOCKER_DIR", "").strip()
  if envDockerDir.len > 0 and fileExists(envDockerDir / "Dockerfile") and fileExists(envDockerDir.parentDir / "pgxcrown.nimble"):
    return envDockerDir

  result = walkUpForDockerDir(getCurrentDir())
  if result.len > 0: return

  let appExe = getAppFilename()
  if appExe.len > 0:
    result = walkUpForDockerDir(appExe.parentDir)
    if result.len > 0: return
    when not defined(windows):
      if symlinkExists(appExe):
        try:
          let resolved = expandSymlink(appExe)
          let absResolved = if resolved.isAbsolute: resolved else: appExe.parentDir / resolved
          result = walkUpForDockerDir(absResolved.parentDir)
          if result.len > 0: return
        except OSError:
          discard

  if isValidPgxcrownRepoDir(CompileTimeRepoRoot):
    return CompileTimeRepoRoot / "docker"
  return ""

proc buildPgxcrownImage*(docker: DockerDriver, pgVersion: int, dockerDir: string): bool =
  ## Builds pgxcrown:<pgVersion> locally using docker/Dockerfile from the repository root.
  let imageTag = getCanonicalImageTag(pgVersion)
  let dockerfile = dockerDir / "Dockerfile"
  let repoRoot = dockerDir.parentDir
  echo "🏗️  [DOCKER BUILD] Image '", imageTag, "' not found locally; building from ", dockerDir, "..."
  let buildArgs = "build --file " & quoteShell(dockerfile) &
                  " --build-arg " & quoteShell("PG_TAG=" & $pgVersion) &
                  " --tag " & quoteShell(imageTag) &
                  " " & quoteShell(repoRoot)
  if docker.execCmdLive(buildArgs) != 0:
    echo "❌ Failed to build Docker image '", imageTag, "' from ", dockerfile
    return false
  if pgVersion == LatestPgVersion:
    discard docker.execCmdRaw("tag " & quoteShell(imageTag) & " " & quoteShell(getPgxcrownImageRepo() & ":latest"))
  return true

proc pullImage*(docker: DockerDriver, imageTag: string): bool =
  echo "📥 [DOCKER PULL] Pulling container image '", imageTag, "'..."
  let (output, exitCode) = docker.execCmdRaw("pull " & quoteShell(imageTag))
  if exitCode != 0:
    echo "❌ Failed to pull Docker image '", imageTag, "': ", output
    return false
  return true

proc resolveImageRepo*(docker: DockerDriver, pgVersion: int): string =
  let custom = getEnv("PGXCROWN_IMAGE", "").strip()
  if custom.len > 0:
    return custom
  if docker.isImagePresent(DefaultLocalImageRepo & ":" & $pgVersion):
    return DefaultLocalImageRepo
  if docker.isImagePresent(DefaultRegistryImageRepo & ":" & $pgVersion):
    return DefaultRegistryImageRepo
  if findPgxcrownDockerDir().len > 0:
    return DefaultLocalImageRepo
  return DefaultRegistryImageRepo

proc resolveCanonicalImageTag*(docker: DockerDriver, pgVersion: int): string {.inline.} =
  docker.resolveImageRepo(pgVersion) & ":" & $pgVersion

proc ensureImage*(docker: DockerDriver, pgVersion: int): bool =
  let repo = docker.resolveImageRepo(pgVersion)
  let imageTag = repo & ":" & $pgVersion
  if docker.isImagePresent(imageTag):
    return true
  let custom = getEnv("PGXCROWN_IMAGE", "").strip()
  if custom.len == 0 and repo == DefaultLocalImageRepo:
    let dockerDir = findPgxcrownDockerDir()
    if dockerDir.len > 0:
      return docker.buildPgxcrownImage(pgVersion, dockerDir)
  if docker.pullImage(imageTag):
    return true
  echo "ℹ️  Hint: pull '", DefaultRegistryImageRepo, ":", pgVersion,
       "' or build locally with: ./docker/build.sh ", pgVersion
  return false

proc removeContainer*(docker: DockerDriver, containerName: string): bool =
  let (_, exitCode) = docker.execCmdRaw("rm -f " & quoteShell(containerName))
  return exitCode == 0

proc startPgContainer*(docker: DockerDriver, containerName: string, pgVersion: int,
                       preloadSupervisor: bool = false): bool =
  discard docker.removeContainer(containerName)

  let imageTag = docker.resolveCanonicalImageTag(pgVersion)
  # Run container in background without mapping host ports to prevent any local database conflicts.
  # When shared_preload_libraries restarts are needed, keep PID 1 alive as a lightweight supervisor
  # so pg_ctl restart does not terminate the container.
  var runCmd = "run --name " & quoteShell(containerName) &
               " -e POSTGRES_PASSWORD=postgres" &
               " -e POSTGRES_HOST_AUTH_METHOD=trust -d"
  if preloadSupervisor:
    let superCmd = "docker-entrypoint.sh postgres >/tmp/pg_stdout.log 2>&1 & " &
                   "trap 'exit 0' TERM INT; while :; do sleep 1; done"
    runCmd.add " --entrypoint bash " & quoteShell(imageTag) & " -lc " & quoteShell(superCmd)
  else:
    runCmd.add " " & quoteShell(imageTag)

  let (output, exitCode) = docker.execCmdRaw(runCmd)
  if exitCode != 0:
    echo "❌ Failed to start Docker container '", containerName, "' with image '", imageTag, "': ", output
    return false
  return true

proc execInContainer*(docker: DockerDriver, containerName: string, cmd: string): (string, int) =
  let execCmd = "exec " & quoteShell(containerName) & " " & cmd
  return docker.execCmdRaw(execCmd)

proc copyIntoContainer*(docker: DockerDriver, containerName: string, srcPath: string, destPath: string): bool =
  let cpCmd = "cp " & quoteShell(srcPath) & " " & quoteShell(containerName & ":" & destPath)
  let (output, exitCode) = docker.execCmdRaw(cpCmd)
  if exitCode != 0:
    echo "❌ Failed to copy '", srcPath, "' to Docker container '", containerName, ":", destPath, "': ", output
    return false
  return true
