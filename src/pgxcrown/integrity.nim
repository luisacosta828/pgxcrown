## =============================================================================
## Pure-Nim FIPS 180-4 SHA-256, RFC 4231 HMAC-SHA256 & Integrity Manifests
## =============================================================================
## Designed with zero OS process / file-mutation / OpenSSL dependencies so it
## compiles cleanly inside both static `pgxtool` and PostgreSQL extension `.so`s.

import std/[algorithm, json, os, strutils]

const
  IntegritySchemaVersion* = 1
  HexDigits = "0123456789abcdef"

  Sha256InitH: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]

  Sha256K: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
  ]

type
  Sha256Ctx = object
    state: array[8, uint32]
    totalBytes: uint64
    buf: array[64, uint8]
    bufLen: int

  FunctionAttestation* = object
    sqlName*: string
    sigKey*: string
    cSymbol*: string
    probin*: string
    lang*: string
    securityDefiner*: bool
    volatility*: char
    searchPath*: string

  IntegrityManifest* = object
    schemaVersion*: int
    extension*: string
    version*: string
    soSha256*: string
    sqlSha256*: string
    controlSha256*: string
    functions*: seq[FunctionAttestation]
    hmacSha256*: string

proc rotr32(x: uint32, n: uint32): uint32 {.inline.} =
  (x shr n) or (x shl (32'u32 - n))

proc sha256Compress(state: var array[8, uint32], blk: openArray[uint8]) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    let j = i * 4
    w[i] = (uint32(blk[j]) shl 24) or
           (uint32(blk[j + 1]) shl 16) or
           (uint32(blk[j + 2]) shl 8) or
           uint32(blk[j + 3])
  for i in 16 ..< 64:
    let s0 = rotr32(w[i - 15], 7'u32) xor rotr32(w[i - 15], 18'u32) xor (w[i - 15] shr 3'u32)
    let s1 = rotr32(w[i - 2], 17'u32) xor rotr32(w[i - 2], 19'u32) xor (w[i - 2] shr 10'u32)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1

  var
    a = state[0]
    b = state[1]
    c = state[2]
    d = state[3]
    e = state[4]
    f = state[5]
    g = state[6]
    h = state[7]

  for i in 0 ..< 64:
    let bigS1 = rotr32(e, 6'u32) xor rotr32(e, 11'u32) xor rotr32(e, 25'u32)
    let ch = (e and f) xor ((not e) and g)
    let temp1 = h + bigS1 + ch + Sha256K[i] + w[i]
    let bigS0 = rotr32(a, 2'u32) xor rotr32(a, 13'u32) xor rotr32(a, 22'u32)
    let maj = (a and b) xor (a and c) xor (b and c)
    let temp2 = bigS0 + maj
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2

  state[0] += a
  state[1] += b
  state[2] += c
  state[3] += d
  state[4] += e
  state[5] += f
  state[6] += g
  state[7] += h

proc initSha256(ctx: var Sha256Ctx) =
  ctx.state = Sha256InitH
  ctx.totalBytes = 0'u64
  ctx.bufLen = 0

proc updateSha256(ctx: var Sha256Ctx, data: openArray[uint8]) =
  if data.len == 0:
    return
  ctx.totalBytes += uint64(data.len)
  var pos = 0

  if ctx.bufLen > 0:
    let take = min(64 - ctx.bufLen, data.len)
    for i in 0 ..< take:
      ctx.buf[ctx.bufLen + i] = data[i]
    ctx.bufLen += take
    pos += take
    if ctx.bufLen == 64:
      sha256Compress(ctx.state, ctx.buf)
      ctx.bufLen = 0

  while pos + 64 <= data.len:
    sha256Compress(ctx.state, data.toOpenArray(pos, pos + 63))
    pos += 64

  while pos < data.len:
    ctx.buf[ctx.bufLen] = data[pos]
    inc ctx.bufLen
    inc pos

proc updateSha256(ctx: var Sha256Ctx, s: string) {.inline.} =
  if s.len > 0:
    ctx.updateSha256(s.toOpenArrayByte(0, s.len - 1))

proc finishSha256(ctx: var Sha256Ctx): array[32, uint8] =
  let bitLen = ctx.totalBytes * 8'u64
  ctx.buf[ctx.bufLen] = 0x80'u8
  inc ctx.bufLen

  if ctx.bufLen > 56:
    while ctx.bufLen < 64:
      ctx.buf[ctx.bufLen] = 0'u8
      inc ctx.bufLen
    sha256Compress(ctx.state, ctx.buf)
    ctx.bufLen = 0

  while ctx.bufLen < 56:
    ctx.buf[ctx.bufLen] = 0'u8
    inc ctx.bufLen

  for i in 0 ..< 8:
    ctx.buf[56 + i] = uint8((bitLen shr uint64((7 - i) * 8)) and 0xff'u64)

  sha256Compress(ctx.state, ctx.buf)

  for i in 0 ..< 8:
    let word = ctx.state[i]
    result[i * 4] = uint8((word shr 24'u32) and 0xff'u32)
    result[i * 4 + 1] = uint8((word shr 16'u32) and 0xff'u32)
    result[i * 4 + 2] = uint8((word shr 8'u32) and 0xff'u32)
    result[i * 4 + 3] = uint8(word and 0xff'u32)

proc digestToHex(digest: array[32, uint8]): string =
  result = newString(64)
  for i in 0 ..< 32:
    let b = int(digest[i])
    result[i * 2] = HexDigits[b shr 4]
    result[i * 2 + 1] = HexDigits[b and 0x0f]

proc sha256Digest(data: string): array[32, uint8] =
  var ctx: Sha256Ctx
  initSha256(ctx)
  updateSha256(ctx, data)
  finishSha256(ctx)

proc sha256Hex*(data: string): string =
  ## Computes lowercase 64-char FIPS 180-4 SHA-256 hex digest of `data`.
  digestToHex(sha256Digest(data))

proc sha256File*(path: string): string =
  ## Streams a file in 64 KiB chunks and returns its lowercase 64-char SHA-256 digest.
  if '\0' in path:
    raise newException(ValueError, "File path contains prohibited NUL byte")
  if path.len == 0:
    raise newException(ValueError, "File path cannot be empty")
  if dirExists(path):
    raise newException(IOError, "Cannot compute SHA-256 of directory: " & path)
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)

  var f = open(path, fmRead)
  try:
    var ctx: Sha256Ctx
    initSha256(ctx)
    var buf: array[65536, uint8]
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n > 0:
        updateSha256(ctx, buf.toOpenArray(0, n - 1))
      if n < buf.len:
        if not endOfFile(f):
          raise newException(IOError, "Failed to read file completely: " & path)
        break
    result = digestToHex(finishSha256(ctx))
  finally:
    close(f)

proc hmacSha256Hex*(key, data: string): string =
  ## Computes RFC 4231 HMAC-SHA256 returning lowercase 64-char hex.
  var kBlock: array[64, uint8]
  if key.len > 64:
    let hashedKey = sha256Digest(key)
    for i in 0 ..< 32:
      kBlock[i] = hashedKey[i]
  else:
    for i in 0 ..< key.len:
      kBlock[i] = uint8(ord(key[i]))

  var ipad: array[64, uint8]
  var opad: array[64, uint8]
  for i in 0 ..< 64:
    ipad[i] = kBlock[i] xor 0x36'u8
    opad[i] = kBlock[i] xor 0x5c'u8

  var innerCtx: Sha256Ctx
  initSha256(innerCtx)
  updateSha256(innerCtx, ipad)
  updateSha256(innerCtx, data)
  let innerDigest = finishSha256(innerCtx)

  var outerCtx: Sha256Ctx
  initSha256(outerCtx)
  updateSha256(outerCtx, opad)
  updateSha256(outerCtx, innerDigest)
  digestToHex(finishSha256(outerCtx))

proc constantTimeEquals*(a, b: string): bool =
  ## Constant-time byte comparison of two strings (resistant to early-exit timing leaks).
  var diff = uint32(a.len xor b.len)
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    diff = diff or uint32(ord(a[i]) xor ord(b[i]))
  diff == 0'u32

proc compareAttestations*(a, b: FunctionAttestation): int =
  result = cmp(a.sigKey, b.sigKey)
  if result == 0:
    result = cmp(a.cSymbol, b.cSymbol)
  if result == 0:
    result = cmp(a.sqlName, b.sqlName)

proc sortAttestations*(fns: openArray[FunctionAttestation]): seq[FunctionAttestation] =
  result = @fns
  result.sort(compareAttestations)

proc functionAttestationToJson*(f: FunctionAttestation): JsonNode =
  result = newJObject()
  result["sqlName"] = newJString(f.sqlName)
  result["sigKey"] = newJString(f.sigKey)
  result["cSymbol"] = newJString(f.cSymbol)
  result["probin"] = newJString(f.probin)
  result["lang"] = newJString(f.lang)
  result["securityDefiner"] = newJBool(f.securityDefiner)
  result["volatility"] = newJString($f.volatility)
  result["searchPath"] = newJString(f.searchPath)

proc requireStringField(obj: JsonNode, key: string, allowEmpty: bool = false): string =
  if not obj.hasKey(key) or obj[key].kind != JString:
    raise newException(ValueError, "Missing or invalid string field '" & key & "'")
  result = obj[key].getStr()
  if not allowEmpty and result.len == 0:
    raise newException(ValueError, "Field '" & key & "' cannot be empty")

proc jsonToFunctionAttestation*(n: JsonNode): FunctionAttestation =
  if n == nil or n.kind != JObject:
    raise newException(ValueError, "FunctionAttestation entry must be a JSON object")
  result.sqlName = requireStringField(n, "sqlName")
  result.sigKey = requireStringField(n, "sigKey")
  result.cSymbol = requireStringField(n, "cSymbol")
  result.probin = requireStringField(n, "probin")
  result.lang = requireStringField(n, "lang")
  if not n.hasKey("securityDefiner") or n["securityDefiner"].kind != JBool:
    raise newException(ValueError, "Missing or invalid boolean field 'securityDefiner'")
  result.securityDefiner = n["securityDefiner"].getBool()
  let volStr = requireStringField(n, "volatility")
  if volStr.len != 1 or volStr[0] notin {'i', 's', 'v'}:
    raise newException(ValueError, "Invalid volatility value '" & volStr & "' (expected 'i', 's', or 'v')")
  result.volatility = volStr[0]
  result.searchPath = requireStringField(n, "searchPath", allowEmpty = true)

proc functionsToJson*(fns: openArray[FunctionAttestation]): JsonNode =
  result = newJArray()
  for f in sortAttestations(fns):
    result.add(functionAttestationToJson(f))

proc jsonToFunctions*(n: JsonNode): seq[FunctionAttestation] =
  if n == nil or n.kind != JArray:
    raise newException(ValueError, "Functions metadata must be a JSON array")
  result = @[]
  for item in n:
    result.add(jsonToFunctionAttestation(item))

proc canonicalPayloadJsonNode(m: IntegrityManifest): JsonNode =
  result = newJObject()
  result["schemaVersion"] = newJInt(m.schemaVersion)
  result["extension"] = newJString(m.extension)
  result["version"] = newJString(m.version)
  result["soSha256"] = newJString(m.soSha256)
  result["sqlSha256"] = newJString(m.sqlSha256)
  result["controlSha256"] = newJString(m.controlSha256)
  result["functions"] = functionsToJson(m.functions)

proc canonicalManifestPayload*(m: IntegrityManifest): string =
  ## Produces deterministic compact canonical JSON for `m` excluding `hmacSha256`.
  $canonicalPayloadJsonNode(m)

proc signManifest*(m: var IntegrityManifest, key: string) =
  ## Signs `m` in-place using HMAC-SHA256 over `canonicalManifestPayload(m)`.
  if key.len == 0:
    raise newException(ValueError, "HMAC signing key cannot be empty")
  m.hmacSha256 = hmacSha256Hex(key, canonicalManifestPayload(m))

proc verifyManifestSignature*(m: IntegrityManifest, key: string): bool =
  ## Verifies `m.hmacSha256` against `key` using constant-time equality.
  if key.len == 0 or m.hmacSha256.len != 64:
    return false
  let expected = hmacSha256Hex(key, canonicalManifestPayload(m))
  constantTimeEquals(m.hmacSha256, expected)

proc manifestToJson*(m: IntegrityManifest): JsonNode =
  result = canonicalPayloadJsonNode(m)
  result["hmacSha256"] = newJString(m.hmacSha256)

proc jsonToManifest*(n: JsonNode): IntegrityManifest =
  if n == nil or n.kind != JObject:
    raise newException(ValueError, "IntegrityManifest root must be a JSON object")
  if not n.hasKey("schemaVersion") or n["schemaVersion"].kind != JInt:
    raise newException(ValueError, "Missing or invalid integer field 'schemaVersion'")
  result.schemaVersion = n["schemaVersion"].getInt()
  if result.schemaVersion != IntegritySchemaVersion:
    raise newException(ValueError, "Unsupported integrity manifest schemaVersion: " & $result.schemaVersion)
  result.extension = requireStringField(n, "extension")
  result.version = requireStringField(n, "version")
  result.soSha256 = requireStringField(n, "soSha256")
  result.sqlSha256 = requireStringField(n, "sqlSha256")
  result.controlSha256 = requireStringField(n, "controlSha256")
  if not n.hasKey("functions") or n["functions"].kind != JArray:
    raise newException(ValueError, "Missing or invalid array field 'functions'")
  result.functions = jsonToFunctions(n["functions"])
  if n.hasKey("hmacSha256"):
    if n["hmacSha256"].kind != JString:
      raise newException(ValueError, "Invalid string field 'hmacSha256'")
    result.hmacSha256 = n["hmacSha256"].getStr()
  else:
    result.hmacSha256 = ""

proc checkSingleArtifact(errs: var seq[string], label, path, expectedHex: string) =
  if '\0' in path:
    errs.add("Invalid " & label & " path (contains prohibited NUL byte)")
    return
  if path.len == 0:
    errs.add("Missing " & label & " path (empty)")
    return
  if dirExists(path) or not fileExists(path):
    errs.add("Missing " & label & ": " & path)
    return
  try:
    let actual = sha256File(path)
    if not constantTimeEquals(actual, expectedHex.toLowerAscii()):
      errs.add(label & " SHA-256 mismatch for " & path &
               " (expected " & expectedHex & ", got " & actual & ")")
  except CatchableError as e:
    errs.add("Failed to read " & label & " (" & path & "): " & e.msg)

proc verifyDiskArtifacts*(m: IntegrityManifest, soPath, sqlPath, controlPath: string): seq[string] =
  ## Verifies `.so`, `.sql`, and `.control` on disk against SHA-256 digests in `m`.
  result = @[]
  checkSingleArtifact(result, "shared library", soPath, m.soSha256)
  checkSingleArtifact(result, "SQL script", sqlPath, m.sqlSha256)
  checkSingleArtifact(result, "control file", controlPath, m.controlSha256)
