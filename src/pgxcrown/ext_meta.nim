## Shared extension metadata, SQL overload symbol mangling, `.control` rendering,
## and schema snapshot diffing helpers for pgxcrown (`pgx.nim` & `pgxtool.nim`).

import std/[algorithm, hashes, json, os, strutils, tables]

type
  ExtensionMeta* = object
    name*: string
    version*: string
    comment*: string
    relocatable*: bool
    hasExplicitRelocatable*: bool
    trusted*: bool
    hasExplicitTrusted*: bool
    schema*: string
    requires*: seq[string]
    source*: string

  EnumSchema* = object
    name*: string
    labels*: seq[string]

  CompositeFieldSchema* = object
    name*: string
    sqlType*: string

  CompositeSchema* = object
    name*: string
    fields*: seq[CompositeFieldSchema]

  BaseTypeSchema* = object
    name*: string
    ddl*: string

  RoutineSchema* = object
    sigKey*: string
    ddl*: string

  CustomSqlSchema* = object
    id*: string
    phase*: string
    ddl*: string

  SchemaSnapshot* = object
    version*: string
    enums*: seq[EnumSchema]
    composites*: seq[CompositeSchema]
    baseTypes*: seq[BaseTypeSchema]
    routines*: seq[RoutineSchema]
    customSql*: seq[CustomSqlSchema]

proc sanitizeSlugToken(raw: string): string =
  result = ""
  for ch in raw:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}:
      result.add(toLowerAscii(ch))
    elif ch == '_' and (result.len == 0 or result[^1] != '_'):
      result.add('_')
  result = result.strip(chars = {'_'})
  if result.len == 0:
    result = "t"

proc sqlTypeToSlug*(sqlType: string): string =
  ## Converts a PostgreSQL SQL type name (e.g. `int4[]`, `"PaymentState"`) into a C-safe slug.
  var s = sqlType.strip()
  var prefix = ""
  while s.endsWith("[]"):
    prefix.add("arr_")
    s = s[0 .. ^3].strip()
  if s.startsWith("\"") and s.endsWith("\"") and s.len >= 2:
    s = s[1 .. ^2]
  let lower = s.toLowerAscii()
  let baseSlug =
    case lower
    of "double precision": "float8"
    of "character varying": "varchar"
    else: sanitizeSlugToken(s)
  result = prefix & baseSlug

proc normalizeSqlTypeKey*(sqlType: string): string =
  ## Normalizes a PostgreSQL SQL parameter type for overload collision checking.
  var s = sqlType.strip()
  var suffix = ""
  while s.endsWith("[]"):
    suffix.add("[]")
    s = s[0 .. ^3].strip()
  if s.startsWith("\"") and s.endsWith("\"") and s.len >= 2:
    let unquoted = s[1 .. ^2]
    if unquoted == "char":
      return "\"char\"" & suffix
    return unquoted.toLowerAscii() & suffix
  case s.toLowerAscii()
  of "int", "integer", "int4": "int4" & suffix
  of "bigint", "int8": "int8" & suffix
  of "smallint", "int2": "int2" & suffix
  of "real", "float4": "float4" & suffix
  of "double precision", "float8": "float8" & suffix
  of "bool", "boolean": "boolean" & suffix
  of "text": "text" & suffix
  else: s.toLowerAscii() & suffix

proc buildMangledCSymbol*(fnName: string, paramSqlTypes: seq[string]): string =
  ## Builds a deterministic, Nim- and C-safe exported symbol name for overloaded SQL functions/iterators.
  let slug =
    if paramSqlTypes.len == 0:
      "void"
    else:
      var parts: seq[string] = @[]
      for pt in paramSqlTypes:
        parts.add(sqlTypeToSlug(pt))
      parts.join("_")
  let sigRaw = fnName & "(" & paramSqlTypes.join(",") & ")"
  let hShort = toHex(abs(hash(sigRaw)), 6).toLowerAscii()
  let fnPart = sanitizeSlugToken(fnName)
  let base = "pgx_" & fnPart & "_" & hShort & "_" & slug
  if base.len <= 56:
    return base
  let hHex = toHex(abs(hash(sigRaw)), 8).toLowerAscii()
  let maxPrefix = max(12, 63 - 9)
  let prefix = base[0 ..< min(base.len, maxPrefix)].strip(chars = {'_'})
  result = prefix & "_" & hHex

proc validateSafeIdentList*(raw: string, contextName: string): (seq[string], string) =
  ## Parses and validates comma-separated SQL/extension identifiers (rejecting injection chars).
  var items: seq[string] = @[]
  for part in raw.split(','):
    let cleaned = part.strip()
    if cleaned.len == 0:
      continue
    if cleaned.toLowerAscii() == "$user":
      if contextName != "searchPath":
        return (@[], contextName & " contains invalid identifier '$user'")
      items.add("\"$user\"")
      continue
    for idx, ch in cleaned:
      let validFirst = ch in {'a'..'z', 'A'..'Z', '_'}
      let validCont = validFirst or (ch in {'0'..'9'})
      if (idx == 0 and not validFirst) or (idx > 0 and not validCont):
        return (@[], contextName & " contains unsafe character in identifier '" & cleaned & "'")
    items.add(cleaned)
  if items.len == 0:
    return (@[], contextName & " cannot be empty")
  (items, "")

proc initDefaultExtensionMeta*(prjName: string): ExtensionMeta =
  ExtensionMeta(
    name: prjName,
    version: "0.1.0",
    comment: prjName & " extension for PostgreSQL",
    relocatable: true,
    hasExplicitRelocatable: false,
    trusted: false,
    hasExplicitTrusted: false,
    schema: "",
    requires: @[],
    source: "default"
  )

proc applyNimbleMeta*(projectDir: string, meta: var ExtensionMeta): bool =
  if projectDir.len == 0 or not dirExists(projectDir):
    return false
  var nimbleFiles: seq[string] = @[]
  for kind, path in walkDir(projectDir):
    if kind == pcFile and path.endsWith(".nimble"):
      nimbleFiles.add(path)
  if nimbleFiles.len == 0:
    return false
  nimbleFiles.sort()
  let content = readFile(nimbleFiles[0])
  var foundAny = false
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#") or '=' notin trimmed:
      continue
    let parts = trimmed.split('=', maxsplit = 1)
    if parts.len != 2:
      continue
    let k = parts[0].strip().toLowerAscii()
    let v = parts[1].strip().strip(chars = {'"', '\''})
    if k == "version" and v.len > 0:
      meta.version = v
      meta.source = "nimble"
      foundAny = true
    elif k == "description" and v.len > 0 and meta.comment.endsWith(" extension for PostgreSQL"):
      meta.comment = v
  foundAny

proc applyPgxExtJson*(projectDir: string, meta: var ExtensionMeta): bool =
  if projectDir.len == 0:
    return false
  let cfgPath = projectDir / "pgxext.json"
  if not fileExists(cfgPath):
    return false
  let obj = parseJson(readFile(cfgPath))
  if obj.kind != JObject:
    raise newException(ValueError, "pgxext.json root must be a JSON object: " & cfgPath)
  if obj.hasKey("version") and obj["version"].kind == JString:
    let v = obj["version"].getStr().strip()
    if v.len > 0:
      meta.version = v
  if obj.hasKey("comment") and obj["comment"].kind == JString:
    meta.comment = obj["comment"].getStr()
  if obj.hasKey("relocatable") and obj["relocatable"].kind == JBool:
    meta.relocatable = obj["relocatable"].getBool()
    meta.hasExplicitRelocatable = true
  if obj.hasKey("trusted") and obj["trusted"].kind == JBool:
    meta.trusted = obj["trusted"].getBool()
    meta.hasExplicitTrusted = true
  if obj.hasKey("schema") and obj["schema"].kind == JString:
    meta.schema = obj["schema"].getStr().strip()
  if obj.hasKey("requires"):
    let reqNode = obj["requires"]
    if reqNode.kind == JArray:
      meta.requires = @[]
      for item in reqNode:
        if item.kind == JString and item.getStr().strip().len > 0:
          meta.requires.add(item.getStr().strip())
    elif reqNode.kind == JString and reqNode.getStr().strip().len > 0:
      meta.requires = @[]
      for item in reqNode.getStr().split(','):
        if item.strip().len > 0:
          meta.requires.add(item.strip())
  meta.source = "pgxext.json"
  true

proc finalizeAndValidateMeta*(meta: var ExtensionMeta): string =
  if meta.version.len == 0:
    return "Extension version cannot be empty"
  if "--" in meta.version or "/" in meta.version or "\\" in meta.version or ".." in meta.version:
    return "Invalid extension version '" & meta.version & "' (must not contain '--', '/', or '..')"
  for ch in meta.version:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '+', '-'}:
      return "Invalid character '" & ch & "' in extension version '" & meta.version & "'"
  for ch in meta.comment:
    if ch in {'\n', '\r'}:
      return "Extension comment cannot contain newlines"
  if meta.schema.len > 0:
    let (_, schemaErr) = validateSafeIdentList(meta.schema, "schema")
    if schemaErr.len > 0:
      return schemaErr
    if meta.hasExplicitRelocatable and meta.relocatable:
      return "PostgreSQL forbids setting 'schema' when 'relocatable = true' in .control"
    meta.relocatable = false
  for req in meta.requires:
    let (_, reqErr) = validateSafeIdentList(req, "requires")
    if reqErr.len > 0:
      return reqErr
  ""

proc renderControlFile*(meta: ExtensionMeta): string =
  ## Renders PostgreSQL `<ext>.control` content cleanly.
  let safeComment = meta.comment.replace("'", "''")
  result = "# " & meta.name & " extension\n"
  result.add "comment = '" & safeComment & "'\n"
  result.add "default_version = '" & meta.version & "'\n"
  result.add "module_pathname = '$libdir/" & meta.name & "'\n"
  result.add "relocatable = " & (if meta.relocatable: "true" else: "false") & "\n"
  if meta.trusted:
    result.add "trusted = true\n"
  if meta.schema.len > 0:
    result.add "schema = '" & meta.schema & "'\n"
  if meta.requires.len > 0:
    result.add "requires = '" & meta.requires.join(", ") & "'\n"

proc snapshotToJson*(s: SchemaSnapshot): JsonNode =
  var enumsArr = newJArray()
  for e in s.enums:
    enumsArr.add(%*{"name": e.name, "labels": e.labels})
  var compArr = newJArray()
  for c in s.composites:
    var fArr = newJArray()
    for fld in c.fields:
      fArr.add(%*{"name": fld.name, "sqlType": fld.sqlType})
    compArr.add(%*{"name": c.name, "fields": fArr})
  var baseArr = newJArray()
  for b in s.baseTypes:
    baseArr.add(%*{"name": b.name, "ddl": b.ddl})
  var fnArr = newJArray()
  for r in s.routines:
    fnArr.add(%*{"sigKey": r.sigKey, "ddl": r.ddl})
  var customArr = newJArray()
  for cs in s.customSql:
    let ph = if cs.phase.len > 0: cs.phase else: "post"
    customArr.add(%*{"id": cs.id, "phase": ph, "ddl": cs.ddl})
  %*{
    "version": s.version,
    "enums": enumsArr,
    "composites": compArr,
    "baseTypes": baseArr,
    "routines": fnArr,
    "customSql": customArr
  }

proc jsonToSnapshot*(n: JsonNode): SchemaSnapshot =
  if n.isNil or n.kind != JObject:
    return
  result.version = n.getOrDefault("version").getStr("")
  for e in n.getOrDefault("enums").getElems(@[]):
    var labels: seq[string] = @[]
    for lb in e.getOrDefault("labels").getElems(@[]):
      labels.add(lb.getStr())
    result.enums.add(EnumSchema(name: e.getOrDefault("name").getStr(), labels: labels))
  for c in n.getOrDefault("composites").getElems(@[]):
    var fields: seq[CompositeFieldSchema] = @[]
    for fld in c.getOrDefault("fields").getElems(@[]):
      fields.add(CompositeFieldSchema(name: fld.getOrDefault("name").getStr(), sqlType: fld.getOrDefault("sqlType").getStr()))
    result.composites.add(CompositeSchema(name: c.getOrDefault("name").getStr(), fields: fields))
  for b in n.getOrDefault("baseTypes").getElems(@[]):
    result.baseTypes.add(BaseTypeSchema(name: b.getOrDefault("name").getStr(), ddl: b.getOrDefault("ddl").getStr()))
  for r in n.getOrDefault("routines").getElems(@[]):
    result.routines.add(RoutineSchema(sigKey: r.getOrDefault("sigKey").getStr(), ddl: r.getOrDefault("ddl").getStr()))
  let csNode = n.getOrDefault("customSql")
  if csNode != nil and csNode.kind == JArray:
    for cs in csNode:
      if cs.kind == JObject:
        let rawPh = cs.getOrDefault("phase").getStr("post")
        result.customSql.add(CustomSqlSchema(
          id: cs.getOrDefault("id").getStr(""),
          phase: (if rawPh.len > 0: rawPh else: "post"),
          ddl: cs.getOrDefault("ddl").getStr("")
        ))

proc diffCustomSqlPhase(
  curList: seq[CustomSqlSchema],
  prevMap: Table[string, CustomSqlSchema],
  targetPhase: string,
  stmts: var seq[string]
) =
  for cs in curList:
    let ph = if cs.phase.len > 0: cs.phase else: "post"
    let matchesTarget =
      if targetPhase == "pre": ph == "pre"
      else: ph != "pre"
    if not matchesTarget:
      continue
    let curDdl = cs.ddl.strip()
    if cs.id notin prevMap:
      if curDdl.len > 0:
        stmts.add(curDdl)
    else:
      let oldCs = prevMap[cs.id]
      let oldPh = if oldCs.phase.len > 0: oldCs.phase else: "post"
      let oldDdl = oldCs.ddl.strip()
      if oldDdl != curDdl or oldPh != ph:
        stmts.add(
          "-- NOTE: Custom pgxSql block '" & cs.id & "' changed (" &
          "phase: " & oldPh & " -> " & ph &
          (if oldDdl != curDdl: ", DDL modified" else: "") &
          "); review and apply manual migration if required."
        )

proc diffSnapshotsAndBuildMigration*(prev, cur: SchemaSnapshot): string =
  ## Generates an incremental SQL upgrade script (`ALTER TYPE`, `CREATE TYPE`, `CREATE OR REPLACE`)
  ## between two structured schema snapshots.
  var stmts: seq[string] = @[
    "-- Auto-generated migration from " & prev.version & " to " & cur.version & " by pgxtool",
    "-- Review before running on production databases; custom manual edits in this file are preserved."
  ]

  var prevCustom = initTable[string, CustomSqlSchema]()
  for cs in prev.customSql:
    prevCustom[cs.id] = cs
  var curCustomIds = initTable[string, bool]()
  for cs in cur.customSql:
    curCustomIds[cs.id] = true

  diffCustomSqlPhase(cur.customSql, prevCustom, "pre", stmts)

  var prevBases = initTable[string, BaseTypeSchema]()
  for b in prev.baseTypes:
    prevBases[b.name] = b
  for b in cur.baseTypes:
    if b.name notin prevBases:
      stmts.add(b.ddl.strip())

  var prevEnums = initTable[string, seq[string]]()
  for e in prev.enums:
    prevEnums[e.name] = e.labels
  for e in cur.enums:
    if e.name notin prevEnums:
      var quoted: seq[string] = @[]
      for lb in e.labels:
        quoted.add("'" & lb.replace("'", "''") & "'")
      stmts.add("CREATE TYPE \"" & e.name & "\" AS ENUM (" & quoted.join(", ") & ");")
    else:
      let oldLabels = prevEnums[e.name]
      for lb in e.labels:
        if lb notin oldLabels:
          stmts.add("ALTER TYPE \"" & e.name & "\" ADD VALUE IF NOT EXISTS '" & lb.replace("'", "''") & "';")

  var prevComps = initTable[string, seq[CompositeFieldSchema]]()
  for c in prev.composites:
    prevComps[c.name] = c.fields
  for c in cur.composites:
    if c.name notin prevComps:
      var fLines: seq[string] = @[]
      for fld in c.fields:
        fLines.add("  \"" & fld.name & "\" " & fld.sqlType)
      stmts.add("CREATE TYPE \"" & c.name & "\" AS (\n" & fLines.join(",\n") & "\n);")
    else:
      let oldFields = prevComps[c.name]
      var oldMap = initTable[string, string]()
      for fld in oldFields:
        oldMap[fld.name] = fld.sqlType
      for fld in c.fields:
        if fld.name notin oldMap:
          stmts.add("ALTER TYPE \"" & c.name & "\" ADD ATTRIBUTE \"" & fld.name & "\" " & fld.sqlType & ";")
        elif oldMap[fld.name] != fld.sqlType:
          stmts.add("-- NOTE: Attribute \"" & c.name & "\".\"" & fld.name & "\" changed type from " &
                    oldMap[fld.name] & " to " & fld.sqlType & " (manual ALTER ATTRIBUTE may be required).")

  var prevRoutines = initTable[string, string]()
  for r in prev.routines:
    prevRoutines[r.sigKey] = r.ddl.strip()
  var curRoutineKeys = initTable[string, bool]()
  for r in cur.routines:
    curRoutineKeys[r.sigKey] = true
    let curDdl = r.ddl.strip()
    if r.sigKey notin prevRoutines or prevRoutines[r.sigKey] != curDdl:
      stmts.add(curDdl)
  for r in prev.routines:
    if r.sigKey notin curRoutineKeys:
      stmts.add("-- NOTE: Previous routine signature removed or renamed: " & r.sigKey)

  diffCustomSqlPhase(cur.customSql, prevCustom, "post", stmts)
  for cs in prev.customSql:
    if cs.id notin curCustomIds:
      stmts.add("-- NOTE: Previous pgxSql block removed: " & cs.id)

  result = stmts.join("\n\n") & "\n"
