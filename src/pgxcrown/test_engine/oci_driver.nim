import std/[os, osproc, strutils]

const
  SupportedPgVersions* = [14, 15, 16, 17]
  LatestPgVersion* = SupportedPgVersions[^1] # 17 (latest)

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

proc detectDockerEngine*(): DockerDriver =
  let dockerExe = findExe("docker")
  if dockerExe.len == 0:
    quit("❌ [DOCKER NOT FOUND] Docker is required to run isolated container tests.\nPlease install Docker or start the Docker service.")
  
  let (_, code) = execCmdEx(quoteShell(dockerExe) & " ps")
  if code != 0:
    quit("❌ [DOCKER ERROR] Docker daemon is not running or current user lacks permissions.\nPlease start Docker (e.g. 'sudo systemctl start docker' or check user groups).")

  return DockerDriver(binaryPath: dockerExe)

proc execCmdRaw*(docker: DockerDriver, cmdArgs: string): (string, int) =
  let fullCmd = quoteShell(docker.binaryPath) & " " & cmdArgs
  return execCmdEx(fullCmd)

proc getCanonicalImageTag*(pgVersion: int): string {.inline.} =
  "postgres:" & $pgVersion

proc isImagePresent*(docker: DockerDriver, imageTag: string): bool =
  let (output, exitCode) = docker.execCmdRaw("images -q " & quoteShell(imageTag))
  return exitCode == 0 and output.strip.len > 0

proc pullImage*(docker: DockerDriver, imageTag: string): bool =
  echo "📥 [DOCKER PULL] Pulling container image '", imageTag, "'..."
  let (output, exitCode) = docker.execCmdRaw("pull " & quoteShell(imageTag))
  if exitCode != 0:
    echo "❌ Failed to pull Docker image '", imageTag, "': ", output
    return false
  return true

proc ensureImage*(docker: DockerDriver, pgVersion: int): bool =
  let imageTag = getCanonicalImageTag(pgVersion)
  if not docker.isImagePresent(imageTag):
    return docker.pullImage(imageTag)
  return true

proc removeContainer*(docker: DockerDriver, containerName: string): bool =
  let (_, exitCode) = docker.execCmdRaw("rm -f " & quoteShell(containerName))
  return exitCode == 0

proc startPgContainer*(docker: DockerDriver, containerName: string, pgVersion: int): bool =
  discard docker.removeContainer(containerName)
  
  let imageTag = getCanonicalImageTag(pgVersion)
  # Run container in background without mapping host ports to prevent any local database conflicts
  let runCmd = "run --name " & quoteShell(containerName) &
               " -e POSTGRES_PASSWORD=postgres" &
               " -e POSTGRES_HOST_AUTH_METHOD=trust" &
               " -d " & quoteShell(imageTag)

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
