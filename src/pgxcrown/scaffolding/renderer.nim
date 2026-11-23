## =============================================================================
## Pgxcrown Template Placeholder Renderer & Project Scaffolder
## =============================================================================
## Single-pass `{{placeholder}}` rendering, atomic destination validation,
## project file emission, and automatic IDE/LSP `nim.cfg` generation.
## =============================================================================

import std/[os, sets, strutils, tables]
import ../lsp_config
import ./regex_lite
import ./manifest
import ./registry

proc renderPlaceholders*(input: string, vars: Table[string, string]): string =
  ## Single-pass `{{key}}` placeholder substitution (immune to double expansion).
  result = newStringOfCap(input.len)
  var i = 0
  while i < input.len:
    if i + 1 < input.len and input[i] == '{' and input[i + 1] == '{':
      let closeIdx = input.find("}}", start = i + 2)
      if closeIdx > i + 2:
        let key = input[i + 2 ..< closeIdx].strip()
        if key in vars:
          result.add(vars[key])
          i = closeIdx + 2
          continue
    result.add(input[i])
    inc i

proc buildTemplateVariables*(
  manifest: TemplateManifest,
  projectName: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string]
): Table[string, string] =
  validateProjectName(projectName)
  if hasControlOrNul(pgxcrownVersion) or pgxcrownVersion.len == 0:
    raise newException(ValueError, "Invalid pgxcrown version string: '" & pgxcrownVersion & "'")

  result = initTable[string, string]()
  result["project_name"] = projectName
  result["project_snake"] = toProjectSnake(projectName)
  result["pgxcrown_version"] = pgxcrownVersion

  for k, v in cliVars:
    validateVariableName(k)
    validateVariableValue(k, v)
    if k in ["project_name", "project_snake", "pgxcrown_version"]:
      raise newException(ValueError, "Cannot override reserved template variable '" & k & "' via --var")

  for vDef in manifest.variables:
    let val = if vDef.name in cliVars: cliVars[vDef.name] else: vDef.defaultVal
    validateVariableValue(vDef.name, val)
    if vDef.pattern.len > 0 and not matchesVariablePattern(vDef.pattern, val):
      raise newException(ValueError,
        "Variable '" & vDef.name & "' value '" & val & "' does not match required pattern '" & vDef.pattern & "'")
    result[vDef.name] = val

  for k, v in cliVars:
    if k notin result:
      result[k] = v

proc scaffoldFromTemplate*(
  templateSpec: string,
  destDir: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string] = initTable[string, string](),
  externalTemplatesDir: string = "",
  rawTargetArg: string = "",
  syncLsp: bool = true
): ScaffoldResult =
  ## Validates manifest, SemVer, variable regexes, paths, and symlinks atomically before writing files.
  ## Automatically generates an IDE/LSP-ready `nim.cfg` in `destDir` when `syncLsp` is true.
  if rawTargetArg.len > 0:
    validateTargetArg(rawTargetArg)
  if destDir.len == 0 or hasControlOrNul(destDir):
    raise newException(ValueError, "Invalid destination directory")

  let cleanDest = normalizedPath(absolutePath(destDir)).strip(leading = false, trailing = true, chars = {'/', '\\'})
  if cleanDest.len == 0:
    raise newException(ValueError, "Cannot scaffold at filesystem root")
  when not defined(windows):
    if symlinkExists(cleanDest):
      raise newException(ValueError, "Destination directory cannot be a symlink: " & cleanDest)
  if fileExists(cleanDest):
    raise newException(ValueError, "Destination path already exists as a regular file: " & cleanDest)

  let projectName = cleanDest.lastPathPart
  validateProjectName(projectName)

  let loaded = resolveTemplate(templateSpec, externalTemplatesDir)

  if compareSemVer(pgxcrownVersion, loaded.manifest.minPgxcrownVersion) < 0:
    raise newException(ValueError,
      "Template '" & loaded.manifest.name & "' requires pgxcrown >= " &
      loaded.manifest.minPgxcrownVersion & " (current: " & pgxcrownVersion & ")")

  let vars = buildTemplateVariables(loaded.manifest, projectName, pgxcrownVersion, cliVars)

  type PendingWrite = object
    destRel: string
    destAbs: string
    content: string

  var pending: seq[PendingWrite] = @[]
  var seenDestRels = initHashSet[string]()

  for fEntry in loaded.manifest.files:
    let renderedDestRel = renderPlaceholders(fEntry.destRel, vars)
    validateRelativeTemplatePath(renderedDestRel, "rendered destination path")
    if renderedDestRel in seenDestRels:
      raise newException(ValueError, "Duplicate destination path in template manifest: '" & renderedDestRel & "'")
    seenDestRels.incl(renderedDestRel)

    verifyPathWithinBoundary(cleanDest, renderedDestRel)
    let destAbs = cleanDest / renderedDestRel
    if not isSubPath(destAbs, cleanDest):
      raise newException(ValueError, "Destination path escapes project directory: '" & renderedDestRel & "'")
    if fileExists(destAbs) or dirExists(destAbs):
      raise newException(ValueError, "Refusing to overwrite existing destination path: '" & destAbs & "'")

    let rawContent =
      if loaded.sourceKind == "builtin":
        loaded.embeddedFiles[fEntry.srcRel]
      else:
        verifyPathWithinBoundary(loaded.sourceDir, fEntry.srcRel)
        readFile(loaded.sourceDir / fEntry.srcRel)

    let renderedContent = renderPlaceholders(rawContent, vars)
    pending.add(PendingWrite(
      destRel: renderedDestRel,
      destAbs: destAbs,
      content: renderedContent
    ))

  createDir(cleanDest)
  var written: seq[string] = @[]
  for item in pending:
    createDir(item.destAbs.parentDir)
    writeFile(item.destAbs, item.content)
    written.add(item.destRel)

  if syncLsp:
    discard syncProjectNimCfg(cleanDest)
    if fileExists(cleanDest / "nim.cfg") and "nim.cfg" notin written:
      written.add("nim.cfg")

  ScaffoldResult(
    templateName: loaded.manifest.name,
    sourceKind: loaded.sourceKind,
    destDir: cleanDest,
    projectName: projectName,
    projectSnake: vars["project_snake"],
    writtenFiles: written
  )

proc scaffoldProject*(
  templateSpec: string,
  destDir: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string] = initTable[string, string](),
  externalTemplatesDir: string = "",
  rawTargetArg: string = "",
  syncLsp: bool = true
): ScaffoldResult {.inline.} =
  ## Convenience alias for `scaffoldFromTemplate`.
  scaffoldFromTemplate(
    templateSpec = templateSpec,
    destDir = destDir,
    pgxcrownVersion = pgxcrownVersion,
    cliVars = cliVars,
    externalTemplatesDir = externalTemplatesDir,
    rawTargetArg = rawTargetArg,
    syncLsp = syncLsp
  )

proc instantiateTemplate*(
  templateSpec: string,
  destDir: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string] = initTable[string, string](),
  externalTemplatesDir: string = "",
  rawTargetArg: string = "",
  syncLsp: bool = true
): ScaffoldResult {.inline.} =
  ## Convenience alias for `scaffoldFromTemplate`.
  scaffoldFromTemplate(
    templateSpec = templateSpec,
    destDir = destDir,
    pgxcrownVersion = pgxcrownVersion,
    cliVars = cliVars,
    externalTemplatesDir = externalTemplatesDir,
    rawTargetArg = rawTargetArg,
    syncLsp = syncLsp
  )
