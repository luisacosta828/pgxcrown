## =============================================================================
## Pgxcrown Template Manifest Types, SemVer & Security Hardening
## =============================================================================
## Parses `template.json` manifests and enforces strict path-traversal, symlink,
## NUL/control-character, and SemVer compatibility checks.
## =============================================================================

import std/[json, os, sets, strutils, tables]
import ./regex_lite

type
  TemplateVarDef* = object
    name*: string
    defaultVal*: string
    pattern*: string

  TemplateFileEntry* = object
    srcRel*: string
    destRel*: string

  TemplateManifest* = object
    name*: string
    description*: string
    minPgxcrownVersion*: string
    variables*: seq[TemplateVarDef]
    files*: seq[TemplateFileEntry]

  TemplateSummary* = object
    name*: string
    description*: string
    minPgxcrownVersion*: string
    sourceKind*: string ## "builtin" or "external"
    sourcePath*: string
    variables*: seq[TemplateVarDef]

  BuiltinTemplateRaw* = object
    name*: string
    manifestJson*: string
    files*: seq[tuple[relPath: string, content: string]]

  LoadedTemplate* = object
    manifest*: TemplateManifest
    sourceKind*: string
    sourceDir*: string
    embeddedFiles*: Table[string, string]

  ScaffoldResult* = object
    templateName*: string
    sourceKind*: string
    destDir*: string
    projectName*: string
    projectSnake*: string
    writtenFiles*: seq[string]

  SemVer* = tuple[major, minor, patch: int, pre: string]

proc hasControlOrNul*(s: string): bool =
  ## Returns true if `s` contains NUL (`'\0'`) or any ASCII control char (`< 32` or `127`).
  for ch in s:
    if ord(ch) < 32 or ord(ch) == 127:
      return true
  false

proc hasTraversalSegment*(p: string): bool =
  ## Returns true if any `/`- or `\`-separated path segment is `..`.
  for seg in p.split({'/', '\\'}):
    if seg == "..":
      return true
  false

proc isAbsoluteOrDrivePath*(p: string): bool =
  if p.len == 0:
    return false
  if isAbsolute(p) or p.startsWith("/") or p.startsWith("\\"):
    return true
  if p.len >= 2 and p[0] in {'a'..'z', 'A'..'Z'} and p[1] == ':':
    return true
  false

proc validateProjectName*(name: string) =
  if name.len == 0:
    raise newException(ValueError, "Project name cannot be empty")
  if hasControlOrNul(name):
    raise newException(ValueError, "Project name contains NUL or ASCII control characters")
  if name in [".", ".."] or '/' in name or '\\' in name or hasTraversalSegment(name):
    raise newException(ValueError, "Project name contains invalid path or traversal characters: '" & name & "'")

proc validateTargetArg*(rawTarget: string) =
  if rawTarget.len == 0:
    raise newException(ValueError, "Target project name or path cannot be empty")
  if hasControlOrNul(rawTarget):
    raise newException(ValueError, "Target argument contains NUL or ASCII control characters")
  if hasTraversalSegment(rawTarget):
    raise newException(ValueError, "Path traversal segment '..' is forbidden in target path: '" & rawTarget & "'")

proc validateRelativeTemplatePath*(p: string, contextLabel: string = "template file path") =
  if p.len == 0:
    raise newException(ValueError, contextLabel & " cannot be empty")
  if hasControlOrNul(p):
    raise newException(ValueError, contextLabel & " contains NUL or ASCII control characters")
  if isAbsoluteOrDrivePath(p):
    raise newException(ValueError, contextLabel & " must be relative, got absolute path: '" & p & "'")
  if '\\' in p:
    raise newException(ValueError, contextLabel & " must use '/' separators and no backslashes: '" & p & "'")
  if hasTraversalSegment(p):
    raise newException(ValueError, contextLabel & " contains forbidden '..' traversal segment: '" & p & "'")
  for seg in p.split('/'):
    if seg.len == 0 or seg == "." or seg == "..":
      raise newException(ValueError, contextLabel & " contains invalid path segment in '" & p & "'")

proc validateVariableName*(name: string) =
  if name.len == 0:
    raise newException(ValueError, "Template variable name cannot be empty")
  if hasControlOrNul(name):
    raise newException(ValueError, "Template variable name contains NUL or ASCII control characters")
  for idx, ch in name:
    let validFirst = ch in {'a'..'z', 'A'..'Z', '_'}
    let validCont = validFirst or (ch in {'0'..'9'})
    if (idx == 0 and not validFirst) or (idx > 0 and not validCont):
      raise newException(ValueError, "Invalid template variable name '" & name & "'")

proc validateVariableValue*(name, val: string) =
  if hasControlOrNul(val):
    raise newException(ValueError, "Template variable '" & name & "' value contains NUL or ASCII control characters")

proc toProjectSnake*(name: string): string =
  ## Converts a project directory/extension name into a safe snake_case identifier.
  result = ""
  for i, ch in name:
    if ch in {'a'..'z', '0'..'9'}:
      result.add(ch)
    elif ch in {'A'..'Z'}:
      if i > 0 and name[i - 1] in {'a'..'z', '0'..'9'} and (result.len == 0 or result[^1] != '_'):
        result.add('_')
      result.add(toLowerAscii(ch))
    else:
      if result.len > 0 and result[^1] != '_':
        result.add('_')
  result = result.strip(chars = {'_'})
  if result.len == 0:
    result = "pgx_extension"
  elif result[0] in {'0'..'9'}:
    result = "ext_" & result

proc parseSemVer*(raw: string): SemVer =
  var s = raw.strip()
  if s.len > 0 and s[0] in {'v', 'V'}:
    s = s[1 .. ^1]
  if s.len == 0 or hasControlOrNul(s):
    raise newException(ValueError, "Invalid semantic version: '" & raw & "'")
  let plusIdx = s.find('+')
  if plusIdx >= 0:
    s = s[0 ..< plusIdx]
  var pre = ""
  let dashIdx = s.find('-')
  if dashIdx >= 0:
    pre = s[dashIdx + 1 .. ^1]
    s = s[0 ..< dashIdx]
  let parts = s.split('.')
  if parts.len < 2 or parts.len > 3:
    raise newException(ValueError, "Invalid semantic version (expected major.minor[.patch]): '" & raw & "'")
  for part in parts:
    if part.len == 0:
      raise newException(ValueError, "Invalid empty component in semantic version: '" & raw & "'")
    for ch in part:
      if ch notin DigitChars:
        raise newException(ValueError, "Non-numeric component in semantic version: '" & raw & "'")
  let maj = parseInt(parts[0])
  let min = parseInt(parts[1])
  let pat = if parts.len == 3: parseInt(parts[2]) else: 0
  (major: maj, minor: min, patch: pat, pre: pre)

proc compareSemVer*(a, b: string): int =
  ## Compares two SemVer strings; returns `< 0` if `a < b`, `0` if equal, `> 0` if `a > b`.
  let va = parseSemVer(a)
  let vb = parseSemVer(b)
  if va.major != vb.major: return cmp(va.major, vb.major)
  if va.minor != vb.minor: return cmp(va.minor, vb.minor)
  if va.patch != vb.patch: return cmp(va.patch, vb.patch)
  if va.pre.len == 0 and vb.pre.len > 0: return 1
  if va.pre.len > 0 and vb.pre.len == 0: return -1
  cmp(va.pre, vb.pre)

proc isSubPath*(path, root: string): bool =
  let normPath = normalizedPath(path)
  let normRoot = normalizedPath(root).strip(leading = false, trailing = true, chars = {'/', '\\'})
  if normRoot.len == 0:
    return false
  if normPath == normRoot:
    return true
  normPath.startsWith(normRoot & "/") or normPath.startsWith(normRoot & "\\")

proc resolveRealPrefix*(path: string): string =
  ## Resolves symlinks on existing components of `path` (up to 16 hops) without failing if leaf does not exist yet.
  let absP = normalizedPath(absolutePath(path))
  when defined(windows):
    return absP
  else:
    var cur = absP
    var tailParts: seq[string] = @[]
    while cur.len > 1 and not dirExists(cur) and not fileExists(cur) and not symlinkExists(cur):
      let sp = splitPath(cur)
      if sp.tail.len > 0:
        tailParts.add(sp.tail)
      if sp.head == cur or sp.head.len == 0:
        break
      cur = sp.head.strip(leading = false, trailing = true, chars = {'/'})
      if cur.len == 0:
        cur = "/"
        break

    var hops = 0
    while hops < 16 and symlinkExists(cur):
      inc hops
      let tgt = expandSymlink(cur)
      cur = if isAbsolute(tgt): normalizedPath(tgt) else: normalizedPath(cur.parentDir / tgt)
    if hops >= 16:
      raise newException(ValueError, "Symlink resolution exceeded maximum depth for: " & path)

    for idx in countdown(tailParts.len - 1, 0):
      cur = cur / tailParts[idx]
    normalizedPath(cur)

proc verifyPathWithinBoundary*(rootDir, relPath: string) =
  ## Walks `relPath` segment-by-segment inside `rootDir`, rejecting any symlink that
  ## contains `..`, uses an absolute target, cycles, or resolves outside `rootDir`.
  validateRelativeTemplatePath(relPath, "path")
  let absRoot = normalizedPath(absolutePath(rootDir))
  when not defined(windows):
    if symlinkExists(absRoot):
      raise newException(ValueError, "Directory root itself cannot be a symlink: " & absRoot)
  let realRoot = resolveRealPrefix(absRoot)

  var cur = absRoot
  for seg in relPath.split('/'):
    cur = cur / seg
    when not defined(windows):
      var checkPath = cur
      var hops = 0
      while symlinkExists(checkPath):
        inc hops
        if hops > 16:
          raise newException(ValueError, "Symlink cycle detected at: " & cur)
        let rawTarget = expandSymlink(checkPath)
        if hasControlOrNul(rawTarget):
          raise newException(ValueError, "Symlink target contains NUL or control characters")
        if hasTraversalSegment(rawTarget):
          raise newException(ValueError, "Symlink target contains forbidden '..' traversal: '" & rawTarget & "'")
        if isAbsoluteOrDrivePath(rawTarget):
          raise newException(ValueError, "Symlink target escapes directory boundary via absolute path: '" & rawTarget & "'")
        let nextTarget = normalizedPath(checkPath.parentDir / rawTarget)
        if not isSubPath(nextTarget, absRoot):
          raise newException(ValueError, "Symlink escapes directory boundary: '" & cur & "' -> '" & rawTarget & "'")
        let realNext = resolveRealPrefix(nextTarget)
        if not isSubPath(realNext, realRoot):
          raise newException(ValueError, "Symlink escapes canonical root boundary: '" & cur & "' -> '" & rawTarget & "'")
        checkPath = nextTarget

proc parseTemplateManifest*(jsonText: string, sourceLabel: string = "template.json"): TemplateManifest =
  let root = parseJson(jsonText)
  if root.kind != JObject:
    raise newException(ValueError, sourceLabel & ": root must be a JSON object")

  result.name = root.getOrDefault("name").getStr("").strip()
  if result.name.len == 0 or hasControlOrNul(result.name) or '/' in result.name or '\\' in result.name or hasTraversalSegment(result.name):
    raise newException(ValueError, sourceLabel & ": invalid or missing template 'name'")

  result.description = root.getOrDefault("description").getStr("")
  result.minPgxcrownVersion = root.getOrDefault("minPgxcrownVersion").getStr("").strip()
  if result.minPgxcrownVersion.len == 0:
    raise newException(ValueError, sourceLabel & ": missing required 'minPgxcrownVersion'")
  discard parseSemVer(result.minPgxcrownVersion)

  let varsNode = root.getOrDefault("variables")
  if varsNode != nil and varsNode.kind != JNull:
    if varsNode.kind != JArray:
      raise newException(ValueError, sourceLabel & ": 'variables' must be a JSON array")
    var seenVars = initHashSet[string]()
    for vItem in varsNode:
      if vItem.kind != JObject:
        raise newException(ValueError, sourceLabel & ": each entry in 'variables' must be an object")
      let vName = vItem.getOrDefault("name").getStr("").strip()
      validateVariableName(vName)
      if vName in ["project_name", "project_snake", "pgxcrown_version"]:
        raise newException(ValueError, sourceLabel & ": variable name '" & vName & "' is reserved")
      if vName in seenVars:
        raise newException(ValueError, sourceLabel & ": duplicate variable '" & vName & "'")
      seenVars.incl(vName)
      let vDefault = vItem.getOrDefault("default").getStr("")
      validateVariableValue(vName, vDefault)
      let vPattern = vItem.getOrDefault("pattern").getStr("")
      if vPattern.len > 0:
        discard compileRegex(vPattern)
      result.variables.add(TemplateVarDef(
        name: vName,
        defaultVal: vDefault,
        pattern: vPattern
      ))

  let filesNode = root.getOrDefault("files")
  if filesNode.isNil or filesNode.kind != JArray or filesNode.len == 0:
    raise newException(ValueError, sourceLabel & ": 'files' must be a non-empty JSON array")

  for fItem in filesNode:
    var srcRel = ""
    var destRel = ""
    if fItem.kind == JString:
      srcRel = fItem.getStr()
      destRel = srcRel
    elif fItem.kind == JObject:
      srcRel = fItem.getOrDefault("src").getStr("")
      destRel = fItem.getOrDefault("dest").getStr(srcRel)
    else:
      raise newException(ValueError, sourceLabel & ": each entry in 'files' must be a relative path string or {src, dest} object")

    validateRelativeTemplatePath(srcRel, sourceLabel & " source file path")
    if hasControlOrNul(destRel) or isAbsoluteOrDrivePath(destRel) or '\\' in destRel or hasTraversalSegment(destRel):
      raise newException(ValueError, sourceLabel & ": invalid target path '" & destRel & "'")
    if destRel.len == 0:
      raise newException(ValueError, sourceLabel & ": target file path cannot be empty")
    result.files.add(TemplateFileEntry(srcRel: srcRel, destRel: destRel))
