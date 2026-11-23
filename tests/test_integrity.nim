import std/[json, os, osproc, strtabs, strutils, unittest]
import ../src/pgxcrown/integrity

proc flipOneByte(path: string, offset: int = 0) =
  var data = readFile(path)
  doAssert data.len > offset
  let idx = offset
  data[idx] = chr(ord(data[idx]) xor 0x01)
  writeFile(path, data)

proc buildEnv(extraPath: string, integrityKey: string = "", includeKey: bool = false): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k != "PGX_INTEGRITY_KEY":
      result[k] = v
  if extraPath.len > 0:
    let curPath = getEnv("PATH", "")
    result["PATH"] = extraPath & ":" & curPath
  if includeKey:
    result["PGX_INTEGRITY_KEY"] = integrityKey

suite "Pgxcrown Integrity Attestation - SHA-256, HMAC-SHA256, Manifests & pgxtool verify":

  test "NIST FIPS 180-4 SHA-256 official test vectors":
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu") ==
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
    check sha256Hex("a".repeat(1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    let binData = "\0\x01\xffabc\0"
    check sha256Hex(binData).len == 64
    check sha256Hex(binData) != sha256Hex("\0\x01\xfeabc\0")

  test "RFC 4231 HMAC-SHA256 official test vectors (Cases 1, 2, 3, 4, 6, 7)":
    # Test Case 1
    check hmacSha256Hex('\x0b'.repeat(20), "Hi There") ==
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    # Test Case 2
    check hmacSha256Hex("Jefe", "what do ya want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    # Test Case 3
    check hmacSha256Hex('\xaa'.repeat(20), '\xdd'.repeat(50)) ==
      "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
    # Test Case 4
    var key4 = newString(25)
    for i in 0 ..< 25:
      key4[i] = chr(i + 1)
    check hmacSha256Hex(key4, '\xcd'.repeat(50)) ==
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
    # Test Case 6 (>64 byte key)
    check hmacSha256Hex('\xaa'.repeat(131), "Test Using Larger Than Block-Size Key - Hash Key First") ==
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
    # Test Case 7 (>64 byte key and >64 byte data)
    check hmacSha256Hex(
      '\xaa'.repeat(131),
      "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
    ) == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"

  test "Constant-time comparison, streamed sha256File, and path validation":
    check constantTimeEquals("abcdef", "abcdef")
    check not constantTimeEquals("abcdef", "abcdeg")
    check not constantTimeEquals("abcdef", "bbcdef")
    check not constantTimeEquals("abcdef", "abcde")
    check constantTimeEquals("", "")

    let tmpDir = getTempDir() / ("pgx_int_stream_" & $getCurrentProcessId())
    createDir(tmpDir)
    try:
      # 300 KiB payload spanning multiple 64 KiB readBuffer chunks
      var largePayload = newString(300_000)
      for i in 0 ..< largePayload.len:
        largePayload[i] = chr((i * 31 + 7) and 0xff)
      let largePath = tmpDir / "large.bin"
      writeFile(largePath, largePayload)
      check sha256File(largePath) == sha256Hex(largePayload)

      expect(IOError):
        discard sha256File(tmpDir / "does_not_exist.so")
      expect(IOError):
        discard sha256File(tmpDir)
      expect(ValueError):
        discard sha256File(tmpDir / "bad\0path.so")
      expect(ValueError):
        discard sha256File("")
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)

  test "Manifest canonical payload, HMAC signing, forgery rejection, and corrupt JSON handling":
    let fnA = FunctionAttestation(
      sqlName: "fn_a",
      sigKey: "fn_a(int4)",
      cSymbol: "pgx_fn_a_111111_int4",
      probin: "$libdir/demo_ext",
      lang: "c",
      securityDefiner: false,
      volatility: 'i',
      searchPath: ""
    )
    let fnB = FunctionAttestation(
      sqlName: "fn_b",
      sigKey: "fn_b(text)",
      cSymbol: "pgx_fn_b_222222_text",
      probin: "$libdir/demo_ext",
      lang: "c",
      securityDefiner: true,
      volatility: 's',
      searchPath: "public, pg_catalog"
    )
    var m1 = IntegrityManifest(
      schemaVersion: IntegritySchemaVersion,
      extension: "demo_ext",
      version: "0.1.0",
      soSha256: sha256Hex("fake-so"),
      sqlSha256: sha256Hex("fake-sql"),
      controlSha256: sha256Hex("fake-control"),
      functions: @[fnB, fnA],
      hmacSha256: ""
    )
    var m2 = m1
    m2.functions = @[fnA, fnB]
    check canonicalManifestPayload(m1) == canonicalManifestPayload(m2)

    expect(ValueError):
      signManifest(m1, "")

    signManifest(m1, "my-secret-key")
    check m1.hmacSha256.len == 64
    check verifyManifestSignature(m1, "my-secret-key")
    check not verifyManifestSignature(m1, "wrong-secret-key")
    check not verifyManifestSignature(m1, "")

    # Roundtrip JSON serialization
    let roundtrip = jsonToManifest(parseJson($manifestToJson(m1)))
    check roundtrip == m2 or (
      roundtrip.extension == m1.extension and
      roundtrip.hmacSha256 == m1.hmacSha256 and
      roundtrip.functions == @[fnA, fnB]
    )
    check verifyManifestSignature(roundtrip, "my-secret-key")

    # 1-char forgery in HMAC signature
    var forgedSig = m1
    let lastCh = if forgedSig.hmacSha256[^1] == '0': '1' else: '0'
    forgedSig.hmacSha256[^1] = lastCh
    check not verifyManifestSignature(forgedSig, "my-secret-key")

    # Modifying any manifest field invalidates HMAC signature
    var tamperedVer = m1
    tamperedVer.version = "0.1.1"
    check not verifyManifestSignature(tamperedVer, "my-secret-key")

    var tamperedFn = m1
    tamperedFn.functions[0].securityDefiner = not tamperedFn.functions[0].securityDefiner
    check not verifyManifestSignature(tamperedFn, "my-secret-key")

    # Corrupt JSON validation
    for badJson in [
      "[]",
      "{}",
      """{"schemaVersion": 99, "extension": "e", "version": "1", "soSha256": "a", "sqlSha256": "b", "controlSha256": "c", "functions": []}""",
      """{"schemaVersion": 1, "extension": "", "version": "1", "soSha256": "a", "sqlSha256": "b", "controlSha256": "c", "functions": []}""",
      """{"schemaVersion": 1, "extension": "e", "version": "1", "soSha256": "a", "sqlSha256": "b", "controlSha256": "c", "functions": "not-arr"}""",
      """{"schemaVersion": 1, "extension": "e", "version": "1", "soSha256": "a", "sqlSha256": "b", "controlSha256": "c", "functions": [{"sqlName":"f","sigKey":"f()","cSymbol":"c","probin":"p","lang":"c","securityDefiner":"badbool","volatility":"i","searchPath":""}]}""",
      """{"schemaVersion": 1, "extension": "e", "version": "1", "soSha256": "a", "sqlSha256": "b", "controlSha256": "c", "functions": [{"sqlName":"f","sigKey":"f()","cSymbol":"c","probin":"p","lang":"c","securityDefiner":false,"volatility":"x","searchPath":""}]}"""
    ]:
      expect(ValueError):
        discard jsonToManifest(parseJson(badJson))

  test "1-byte artifact tamper detection via verifyDiskArtifacts":
    let tmpDir = getTempDir() / ("pgx_int_disk_" & $getCurrentProcessId())
    createDir(tmpDir)
    try:
      let soPath = tmpDir / "ext.so"
      let sqlPath = tmpDir / "ext--0.1.0.sql"
      let ctrlPath = tmpDir / "ext.control"
      writeFile(soPath, "ELF_SO_PAYLOAD_0123456789")
      writeFile(sqlPath, "CREATE FUNCTION foo() RETURNS int4 AS '$libdir/ext', 'pgx_foo' LANGUAGE c;\n")
      writeFile(ctrlPath, "default_version = '0.1.0'\n")

      let manifest = IntegrityManifest(
        schemaVersion: IntegritySchemaVersion,
        extension: "ext",
        version: "0.1.0",
        soSha256: sha256File(soPath),
        sqlSha256: sha256File(sqlPath),
        controlSha256: sha256File(ctrlPath),
        functions: @[],
        hmacSha256: ""
      )
      check verifyDiskArtifacts(manifest, soPath, sqlPath, ctrlPath).len == 0

      # NUL byte path rejection
      let nulErrs = verifyDiskArtifacts(manifest, tmpDir & "\0/ext.so", sqlPath, ctrlPath)
      check nulErrs.len == 1
      check "NUL" in nulErrs[0]

      # Missing artifact
      let missErrs = verifyDiskArtifacts(manifest, tmpDir / "missing.so", sqlPath, ctrlPath)
      check missErrs.len == 1
      check "Missing" in missErrs[0]

      # 1-byte tamper in .so
      flipOneByte(soPath, 5)
      let soErrs = verifyDiskArtifacts(manifest, soPath, sqlPath, ctrlPath)
      check soErrs.len == 1
      check "shared library" in soErrs[0]
      flipOneByte(soPath, 5) # restore

      # 1-byte tamper in .sql
      flipOneByte(sqlPath, 10)
      let sqlErrs = verifyDiskArtifacts(manifest, soPath, sqlPath, ctrlPath)
      check sqlErrs.len == 1
      check "SQL script" in sqlErrs[0]
      flipOneByte(sqlPath, 10) # restore

      # 1-byte tamper in .control
      flipOneByte(ctrlPath, 3)
      let ctrlErrs = verifyDiskArtifacts(manifest, soPath, sqlPath, ctrlPath)
      check ctrlErrs.len == 1
      check "control file" in ctrlErrs[0]
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)

  test "pgxtool verify CLI pass/fail, 1-byte tamper, --require-signature, symbol audit, and --installed":
    let repoRoot = currentSourcePath.parentDir.parentDir
    let srcRoot = repoRoot / "src"
    let pgxtoolSrc = srcRoot / "pgxcrown" / "pgxtool.nim"

    let tmpDir = getTempDir() / ("pgx_int_cli_" & $getCurrentProcessId())
    let binDir = tmpDir / "bin"
    let projDir = tmpDir / "demo_ext"
    let projSrc = projDir / "src"
    let pkgLibDir = tmpDir / "pg_pkglib"
    let shareDir = tmpDir / "pg_share"
    let extDir = shareDir / "extension"
    createDir(binDir)
    createDir(projSrc)
    createDir(pkgLibDir)
    createDir(extDir)

    try:
      let pgxtoolExe = tmpDir / "pgxtool_test_cli"
      let compileCmd = "nim c -d:release --mm:arc --hints:off --path:" & quoteShell(srcRoot) &
                       " --nimcache:" & quoteShell(tmpDir / "nimcache") &
                       " -o:" & quoteShell(pgxtoolExe) & " " & quoteShell(pgxtoolSrc)
      let (compOut, compCode) = execCmdEx(compileCmd)
      doAssert compCode == 0, "Failed to compile pgxtool for CLI test:\n" & compOut

      # Fake pg_config in binDir for --installed simulation without modifying system PG dirs
      let fakePgConfig = binDir / "pg_config"
      writeFile(fakePgConfig, """#!/bin/bash
case "$1" in
  --pkglibdir) echo """ & quoteShell(pkgLibDir) & """ ;;
  --sharedir) echo """ & quoteShell(shareDir) & """ ;;
  --version) echo "PostgreSQL 18.0" ;;
  *) echo "" ;;
esac
""")
      doAssert execCmd("chmod +x " & quoteShell(fakePgConfig)) == 0

      # Compile real clean ELF shared library and a malicious ELF with blocked `system` call
      let cleanC = tmpDir / "clean_ext.c"
      writeFile(cleanC, "int pgx_clean_add(int a, int b) { return a + b; }\n")
      let soPath = projSrc / "demo_ext.so"
      doAssert execCmd("gcc -shared -fPIC -O2 " & quoteShell(cleanC) & " -o " & quoteShell(soPath)) == 0

      let sqlPath = projSrc / "demo_ext--0.1.0.sql"
      let ctrlPath = projSrc / "demo_ext.control"
      writeFile(sqlPath, "CREATE OR REPLACE FUNCTION clean_add(int4, int4) RETURNS int4 AS '$libdir/demo_ext', 'pgx_clean_add' LANGUAGE c IMMUTABLE STRICT;\n")
      writeFile(ctrlPath, "default_version = '0.1.0'\nmodule_pathname = '$libdir/demo_ext'\nrelocatable = true\n")

      let fnAtt = FunctionAttestation(
        sqlName: "clean_add",
        sigKey: "clean_add(int4,int4)",
        cSymbol: "pgx_clean_add",
        probin: "$libdir/demo_ext",
        lang: "c",
        securityDefiner: false,
        volatility: 'i',
        searchPath: ""
      )
      var manifest = IntegrityManifest(
        schemaVersion: IntegritySchemaVersion,
        extension: "demo_ext",
        version: "0.1.0",
        soSha256: sha256File(soPath),
        sqlSha256: sha256File(sqlPath),
        controlSha256: sha256File(ctrlPath),
        functions: @[fnAtt],
        hmacSha256: ""
      )
      let manifestPath = projSrc / "demo_ext.integrity.json"
      writeFile(manifestPath, pretty(manifestToJson(manifest)))

      # 1. Unsigned verify passes without --require-signature
      let envNoKey = buildEnv(binDir, includeKey = false)
      var (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir), env = envNoKey)
      check code == 0
      check "INTEGRITY VERIFIED" in outp

      # 2. Unsigned verify fails with --require-signature
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature",
                               env = buildEnv(binDir, "secret-key-123", includeKey = true))
      check code != 0
      check "INTEGRITY VIOLATION" in outp

      # 3. Signed manifest passes with matching key (both with and without --require-signature)
      let testKey = "prod-attestation-key-2026"
      signManifest(manifest, testKey)
      writeFile(manifestPath, pretty(manifestToJson(manifest)))

      let envGoodKey = buildEnv(binDir, testKey, includeKey = true)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature", env = envGoodKey)
      check code == 0
      check "INTEGRITY VERIFIED" in outp

      # 4. Signed manifest fails if PGX_INTEGRITY_KEY is missing or wrong
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir), env = envNoKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp

      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature",
                               env = buildEnv(binDir, "wrong-key", includeKey = true))
      check code != 0
      check "INTEGRITY VIOLATION" in outp

      # 5. 1-byte tamper detection on .so, .sql, .control, and corrupt manifest
      flipOneByte(soPath, 0)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature", env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp
      flipOneByte(soPath, 0)

      flipOneByte(sqlPath, 0)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature", env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp
      flipOneByte(sqlPath, 0)

      flipOneByte(ctrlPath, 0)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature", env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp
      flipOneByte(ctrlPath, 0)

      let savedManifestText = readFile(manifestPath)
      writeFile(manifestPath, "{corrupt json")
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir), env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp

      removeFile(manifestPath)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir), env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp
      writeFile(manifestPath, savedManifestText)

      # 6. --installed simulation
      copyFile(soPath, pkgLibDir / "demo_ext.so")
      copyFile(ctrlPath, extDir / "demo_ext.control")
      copyFile(sqlPath, extDir / "demo_ext--0.1.0.sql")
      copyFile(manifestPath, extDir / "demo_ext.integrity.json")

      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify demo_ext --installed --require-signature", env = envGoodKey)
      check code == 0
      check "INTEGRITY VERIFIED" in outp

      flipOneByte(pkgLibDir / "demo_ext.so", 0)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify demo_ext --installed --require-signature", env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp
      flipOneByte(pkgLibDir / "demo_ext.so", 0)

      flipOneByte(extDir / "demo_ext--0.1.0.sql", 0)
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify demo_ext --installed --require-signature", env = envGoodKey)
      check code != 0
      check "INTEGRITY VIOLATION" in outp

      # 7. Even a signed .so containing blocked OS symbol `system` must fail auditBinarySymbols
      let evilC = tmpDir / "evil_ext.c"
      writeFile(evilC, "#include <stdlib.h>\nint pgx_evil(const char *s) { return system(s); }\n")
      doAssert execCmd("gcc -shared -fPIC -O2 " & quoteShell(evilC) & " -o " & quoteShell(soPath)) == 0
      manifest.soSha256 = sha256File(soPath)
      signManifest(manifest, testKey)
      writeFile(manifestPath, pretty(manifestToJson(manifest)))
      (outp, code) = execCmdEx(quoteShell(pgxtoolExe) & " verify " & quoteShell(projDir) & " --require-signature", env = envGoodKey)
      check code != 0
      check "SECURITY VIOLATION" in outp
      check "INTEGRITY VIOLATION" in outp
    finally:
      if dirExists(tmpDir):
        removeDir(tmpDir)
