## =============================================================================
## Pgxcrown Template Registry (Builtin staticRead + External Discovery)
## =============================================================================
## Embeds all 6 builtin project templates at compile time (`staticRead`) and
## discovers external templates under `$PGXTOOL_HOME/templates/<name>` or
## explicit `--template <dir>` paths.
## =============================================================================

import std/[algorithm, os, sets, tables]
import ./manifest

const BuiltinTemplates*: seq[BuiltinTemplateRaw] = @[
  BuiltinTemplateRaw(
    name: "starter-udf",
    manifestJson: staticRead("../templates/starter-udf/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/starter-udf/pgxext.json")),
      ("src/main.nim", staticRead("../templates/starter-udf/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/starter-udf/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/starter-udf/regress/expected/01_basic.out")),
      ("README.md", staticRead("../templates/starter-udf/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "base-type",
    manifestJson: staticRead("../templates/base-type/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/base-type/pgxext.json")),
      ("src/main.nim", staticRead("../templates/base-type/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/base-type/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/base-type/regress/expected/01_basic.out")),
      ("README.md", staticRead("../templates/base-type/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "bgworker-service",
    manifestJson: staticRead("../templates/bgworker-service/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/bgworker-service/pgxext.json")),
      ("src/main.nim", staticRead("../templates/bgworker-service/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/bgworker-service/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/bgworker-service/regress/expected/01_basic.out")),
      ("regress/preload", staticRead("../templates/bgworker-service/regress/preload")),
      ("README.md", staticRead("../templates/bgworker-service/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "hook-observability",
    manifestJson: staticRead("../templates/hook-observability/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/hook-observability/pgxext.json")),
      ("src/main.nim", staticRead("../templates/hook-observability/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/hook-observability/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/hook-observability/regress/expected/01_basic.out")),
      ("regress/preload", staticRead("../templates/hook-observability/regress/preload")),
      ("README.md", staticRead("../templates/hook-observability/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "plugin-custom-type",
    manifestJson: staticRead("../templates/plugin-custom-type/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/plugin-custom-type/pgxext.json")),
      ("src/plugin_type.nim", staticRead("../templates/plugin-custom-type/src/plugin_type.nim")),
      ("src/main.nim", staticRead("../templates/plugin-custom-type/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/plugin-custom-type/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/plugin-custom-type/regress/expected/01_basic.out")),
      ("README.md", staticRead("../templates/plugin-custom-type/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "secure-service",
    manifestJson: staticRead("../templates/secure-service/template.json"),
    files: @[
      ("pgxext.json", staticRead("../templates/secure-service/pgxext.json")),
      ("src/main.nim", staticRead("../templates/secure-service/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("../templates/secure-service/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("../templates/secure-service/regress/expected/01_basic.out")),
      ("regress/preload", staticRead("../templates/secure-service/regress/preload")),
      ("README.md", staticRead("../templates/secure-service/README.md"))
    ]
  )
]

proc loadExternalTemplateDir*(dirPath: string): LoadedTemplate =
  if hasControlOrNul(dirPath):
    raise newException(ValueError, "Template directory path contains NUL or control characters")
  let absDir = normalizedPath(absolutePath(dirPath))
  if not dirExists(absDir):
    raise newException(ValueError, "External template directory not found: " & dirPath)
  when not defined(windows):
    if symlinkExists(absDir):
      raise newException(ValueError, "External template directory root cannot be a symlink: " & absDir)
  verifyPathWithinBoundary(absDir, "template.json")
  let manifestPath = absDir / "template.json"
  if not fileExists(manifestPath):
    raise newException(ValueError, "Missing template.json in external template directory: " & absDir)
  let manifest = parseTemplateManifest(readFile(manifestPath), manifestPath)
  for f in manifest.files:
    verifyPathWithinBoundary(absDir, f.srcRel)
    let fullSrc = absDir / f.srcRel
    if not fileExists(fullSrc):
      raise newException(ValueError, "Template file listed in template.json not found: " & fullSrc)
  LoadedTemplate(
    manifest: manifest,
    sourceKind: "external",
    sourceDir: absDir,
    embeddedFiles: initTable[string, string]()
  )

proc loadBuiltinTemplate*(name: string): LoadedTemplate =
  for b in BuiltinTemplates:
    if b.name == name:
      let manifest = parseTemplateManifest(b.manifestJson, "builtin:" & name & "/template.json")
      var fileMap = initTable[string, string]()
      for entry in b.files:
        fileMap[entry.relPath] = entry.content
      for f in manifest.files:
        if f.srcRel notin fileMap:
          raise newException(ValueError, "Builtin template '" & name & "' missing embedded file: " & f.srcRel)
      return LoadedTemplate(
        manifest: manifest,
        sourceKind: "builtin",
        sourceDir: "",
        embeddedFiles: fileMap
      )
  raise newException(ValueError, "Unknown template: '" & name & "'")

proc resolveTemplate*(templateSpec: string, externalTemplatesDir: string = ""): LoadedTemplate =
  ## Resolves a template by explicit directory path, `$PGXTOOL_HOME/templates/<name>`, or builtin name.
  if templateSpec.len == 0:
    raise newException(ValueError, "Template name or path cannot be empty")
  if hasControlOrNul(templateSpec):
    raise newException(ValueError, "Template specification contains NUL or control characters")

  let looksLikePath = templateSpec == "." or '/' in templateSpec or '\\' in templateSpec
  if looksLikePath:
    if hasTraversalSegment(templateSpec):
      raise newException(ValueError, "Template path cannot contain '..' traversal segment: '" & templateSpec & "'")
    return loadExternalTemplateDir(templateSpec)

  if externalTemplatesDir.len > 0:
    let extCand = externalTemplatesDir / templateSpec
    if dirExists(extCand):
      return loadExternalTemplateDir(extCand)

  loadBuiltinTemplate(templateSpec)

proc listAvailableTemplates*(externalTemplatesDir: string = ""): tuple[templates: seq[TemplateSummary], warnings: seq[string]] =
  ## Lists all builtin templates and valid external templates in `externalTemplatesDir`.
  var summaries: seq[TemplateSummary] = @[]
  var warnings: seq[string] = @[]
  var seenExternal = initHashSet[string]()

  if externalTemplatesDir.len > 0 and dirExists(externalTemplatesDir):
    var subdirs: seq[string] = @[]
    for kind, path in walkDir(externalTemplatesDir):
      if kind == pcDir:
        subdirs.add(path)
    subdirs.sort()
    for d in subdirs:
      let manifestFile = d / "template.json"
      if not fileExists(manifestFile):
        continue
      try:
        let loaded = loadExternalTemplateDir(d)
        seenExternal.incl(loaded.manifest.name)
        summaries.add(TemplateSummary(
          name: loaded.manifest.name,
          description: loaded.manifest.description,
          minPgxcrownVersion: loaded.manifest.minPgxcrownVersion,
          sourceKind: "external",
          sourcePath: loaded.sourceDir,
          variables: loaded.manifest.variables
        ))
      except CatchableError as e:
        warnings.add("Skipping invalid external template '" & d & "': " & e.msg)

  for b in BuiltinTemplates:
    if b.name in seenExternal:
      continue
    let loaded = loadBuiltinTemplate(b.name)
    summaries.add(TemplateSummary(
      name: loaded.manifest.name,
      description: loaded.manifest.description,
      minPgxcrownVersion: loaded.manifest.minPgxcrownVersion,
      sourceKind: "builtin",
      sourcePath: "embedded:" & b.name,
      variables: loaded.manifest.variables
    ))

  (templates: summaries, warnings: warnings)
