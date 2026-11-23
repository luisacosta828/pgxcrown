## =============================================================================
## In-Database Runtime Binary & Catalog Integrity Attestation
## =============================================================================

import std/[os, strutils, tables]
import ./ext_meta
import ./integrity
import ./spi
import ./reports/reports

const
  ERRCODE_INSUFFICIENT_PRIVILEGE* = makeSqlState("42501")

type
  IntegrityViolation* = object
    functionName*: string
    code*: string
    detail*: string

  CatalogProcRow = object
    proname: string
    nspname: string
    normArgs: seq[string]
    lanname: string
    probin: string
    prosrc: string
    secDef: bool
    volatility: char
    searchPath: string
    ownerExt: string
    targetExtNsp: string

proc quoteSqlStringLiteral(s: string): string =
  if '\0' in s:
    raise newException(ValueError, "SQL string literal contains prohibited NUL byte")
  "'" & s.replace("'", "''") & "'"

proc extractMappedPathFromLine(line: string): string =
  ## Extracts the pathname (column 6+) from a Linux `/proc/self/maps` line.
  var i = 0
  let n = line.len
  for fieldIdx in 0 ..< 5:
    while i < n and line[i] in {' ', '\t'}:
      inc i
    if i >= n:
      return ""
    while i < n and line[i] notin {' ', '\t'}:
      inc i
  while i < n and line[i] in {' ', '\t'}:
    inc i
  if i >= n:
    return ""
  result = line[i .. ^1].strip()

proc findLoadedSoPath*(extName: string): string {.tags: [].} =
  ## Scans `/proc/self/maps` to locate the live mapped `<extName>.so` shared library.
  if '\0' in extName:
    raise newException(ValueError, "Extension name contains prohibited NUL byte")
  if extName.len == 0 or '/' in extName or '\\' in extName:
    return ""

  let suffixPlain = "/" & extName & ".so"
  let suffixLib = "/lib" & extName & ".so"

  {.cast(tags: []).}:
    if not fileExists("/proc/self/maps"):
      return ""
    var f = open("/proc/self/maps", fmRead)
    try:
      var line = ""
      while f.readLine(line):
        let mapped = extractMappedPathFromLine(line)
        if mapped.len > 0 and mapped[0] == '/' and
           (mapped.endsWith(suffixPlain) or mapped.endsWith(suffixLib)):
          if fileExists(mapped):
            return mapped
    finally:
      close(f)
  return ""

proc loadedSoSha256*(extName: string): string {.tags: [].} =
  ## Locates the live mapped `<extName>.so` via `/proc/self/maps` and computes its SHA-256.
  let soPath = findLoadedSoPath(extName)
  if soPath.len == 0:
    raise newException(IOError, "Loaded shared library not found in /proc/self/maps for extension: " & extName)
  {.cast(tags: []).}:
    result = sha256File(soPath)

proc normalizeArgList(argCsv: string): seq[string] =
  result = @[]
  let trimmed = argCsv.strip()
  if trimmed.len == 0:
    return
  for part in trimmed.split(','):
    let item = part.strip()
    if item.len > 0:
      result.add(normalizeSqlTypeKey(item))

proc parseExpectedSig(att: FunctionAttestation): tuple[fnName: string, normArgs: seq[string]] =
  if att.sigKey.len == 0:
    return (att.sqlName.strip().toLowerAscii(), @[])
  let lp = att.sigKey.find('(')
  let rp = att.sigKey.rfind(')')
  if lp < 0 or rp <= lp:
    return (att.sqlName.strip().toLowerAscii(), @[])
  let fnName = att.sigKey[0 ..< lp].strip().toLowerAscii()
  let inner = att.sigKey[lp + 1 ..< rp]
  (fnName, normalizeArgList(inner))

proc buildCatalogLookupSql(extName: string, expected: openArray[FunctionAttestation]): string =
  var seenNames = initTable[string, bool]()
  var quotedNames: seq[string] = @[]
  for att in expected:
    let rawName = att.sqlName.strip()
    if rawName.len == 0:
      continue
    let lowerName = rawName.toLowerAscii()
    if not seenNames.hasKey(lowerName):
      seenNames[lowerName] = true
      quotedNames.add(quoteSqlStringLiteral(lowerName))
    if rawName != lowerName and not seenNames.hasKey(rawName):
      seenNames[rawName] = true
      quotedNames.add(quoteSqlStringLiteral(rawName))

  let safeExt = quoteSqlStringLiteral(extName)
  let inList = quotedNames.join(", ")
  result = """
SELECT
  p.proname::text AS proname,
  n.nspname::text AS nspname,
  coalesce((
    SELECT string_agg(
      CASE
        WHEN elem.oid IS NOT NULL THEN
          (CASE WHEN elem.typnamespace = 11 AND elem.typname = 'char' THEN '"char"' ELSE elem.typname END) || '[]'
        WHEN t.typnamespace = 11 AND t.typname = 'char' THEN '"char"'
        ELSE t.typname
      END,
      ',' ORDER BY u.pos
    )
    FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY AS u(typid, pos)
    JOIN pg_type t ON t.oid = u.typid
    LEFT JOIN pg_type elem ON elem.oid = t.typelem AND elem.typarray = t.oid
  ), '') AS arg_types,
  l.lanname::text AS lanname,
  coalesce(p.probin, '') AS probin,
  coalesce(p.prosrc, '') AS prosrc,
  p.prosecdef::text AS prosecdef,
  p.provolatile::text AS provolatile,
  coalesce((
    SELECT substring(cfg FROM 13)
    FROM unnest(p.proconfig) AS cfg
    WHERE cfg LIKE 'search_path=%'
    LIMIT 1
  ), '') AS search_path,
  coalesce(e.extname::text, '') AS owner_ext,
  coalesce((
    SELECT n2.nspname::text
    FROM pg_extension e2
    JOIN pg_namespace n2 ON n2.oid = e2.extnamespace
    WHERE e2.extname = """ & safeExt & """
    LIMIT 1
  ), '') AS target_ext_nsp
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
LEFT JOIN pg_depend d
  ON d.classid = 'pg_proc'::regclass
 AND d.objid = p.oid
 AND d.refclassid = 'pg_extension'::regclass
 AND d.deptype = 'e'
LEFT JOIN pg_extension e ON e.oid = d.refobjid
WHERE p.proname IN (""" & inList & """)
ORDER BY p.oid
"""

proc verifyCatalogIntegrity*(extName: string, expected: openArray[FunctionAttestation]): seq[IntegrityViolation] {.tags: [DbReadEffect].} =
  ## Verifies live `pg_proc` / `pg_language` / `pg_depend` / `pg_extension` catalog entries
  ## against compile-time attested function metadata.
  if '\0' in extName:
    raise newException(ValueError, "Extension name contains prohibited NUL byte")
  result = @[]
  if expected.len == 0:
    return

  let sqlQuery = buildCatalogLookupSql(extName, expected)
  let rawRows = fetchRawRows(sqlQuery)

  var rows: seq[CatalogProcRow] = @[]
  for r in rawRows:
    let volStr = r.getOrDefault("provolatile", "")
    let secStr = r.getOrDefault("prosecdef", "").toLowerAscii()
    rows.add CatalogProcRow(
      proname: r.getOrDefault("proname", "").toLowerAscii(),
      nspname: r.getOrDefault("nspname", ""),
      normArgs: normalizeArgList(r.getOrDefault("arg_types", "")),
      lanname: r.getOrDefault("lanname", ""),
      probin: r.getOrDefault("probin", ""),
      prosrc: r.getOrDefault("prosrc", ""),
      secDef: secStr in ["t", "true", "1"],
      volatility: (if volStr.len > 0: volStr[0] else: '\0'),
      searchPath: r.getOrDefault("search_path", ""),
      ownerExt: r.getOrDefault("owner_ext", ""),
      targetExtNsp: r.getOrDefault("target_ext_nsp", "")
    )

  for exp in expected:
    let (expName, expArgs) = parseExpectedSig(exp)
    let fnLabel = if exp.sigKey.len > 0: exp.sigKey else: exp.sqlName

    var matches: seq[CatalogProcRow] = @[]
    for row in rows:
      if row.proname == expName and row.normArgs == expArgs:
        matches.add(row)

    if matches.len == 0:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "FUNCTION_MISSING",
        detail: "Function '" & fnLabel & "' not found in pg_proc"
      )
      continue

    var matched = matches[0]
    var foundOwned = false
    for m in matches:
      if m.ownerExt == extName:
        matched = m
        foundOwned = true
        break
    if not foundOwned:
      for m in matches:
        if m.targetExtNsp.len > 0 and m.nspname == m.targetExtNsp:
          matched = m
          break
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "EXTENSION_DETACHED",
        detail: "Function '" & fnLabel & "' is not owned by extension '" & extName & "' (owner='" & matched.ownerExt & "')"
      )

    if matched.lanname != exp.lang:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "LANGUAGE_TAMPERED",
        detail: "Expected language '" & exp.lang & "', got '" & matched.lanname & "'"
      )

    if matched.probin != exp.probin:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "PROBIN_TAMPERED",
        detail: "Expected probin '" & exp.probin & "', got '" & matched.probin & "'"
      )

    if matched.prosrc != exp.cSymbol:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "PROSRC_TAMPERED",
        detail: "Expected prosrc '" & exp.cSymbol & "', got '" & matched.prosrc & "'"
      )

    if matched.secDef != exp.securityDefiner:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "SECURITY_DEFINER_TAMPERED",
        detail: "Expected prosecdef=" & $exp.securityDefiner & ", got " & $matched.secDef
      )

    if matched.volatility != exp.volatility:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "VOLATILITY_TAMPERED",
        detail: "Expected provolatile='" & $exp.volatility & "', got '" & $matched.volatility & "'"
      )

    if matched.searchPath != exp.searchPath:
      result.add IntegrityViolation(
        functionName: fnLabel,
        code: "SEARCH_PATH_TAMPERED",
        detail: "Expected search_path='" & exp.searchPath & "', got '" & matched.searchPath & "'"
      )

proc isCatalogIntact*(extName: string, expected: openArray[FunctionAttestation]): bool {.tags: [DbReadEffect].} =
  ## Returns true if all expected routines match live catalog state with zero violations.
  verifyCatalogIntegrity(extName, expected).len == 0

proc assertCatalogIntact*(extName: string, expected: openArray[FunctionAttestation]) {.tags: [DbReadEffect].} =
  ## Raises `PostgresError` with SQLSTATE 42501 (`ERRCODE_INSUFFICIENT_PRIVILEGE`) on any violation.
  let violations = verifyCatalogIntegrity(extName, expected)
  if violations.len == 0:
    return
  var codes: seq[string] = @[]
  var details: seq[string] = @[]
  for v in violations:
    codes.add(v.code & "(" & v.functionName & ")")
    details.add(v.code & " [" & v.functionName & "]: " & v.detail)
  var ex = newException(
    PostgresError,
    "Catalog integrity violation detected for extension '" & extName & "': " & codes.join(", ")
  )
  ex.sqlerrcode = ERRCODE_INSUFFICIENT_PRIVILEGE
  ex.detail = details.join("; ")
  raise ex
