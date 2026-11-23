## Layer 3: Extension bundle integrity & HMAC-SHA256 attestation check.
## Pure stdlib only; static musl-gcc compatible.

import std/[json, os]
import ./policy
import ../integrity

proc validateManifestAndArtifacts(ctx: AuditContext, expectedKey: string, requireSignature: bool): LayerReport =
  result = LayerReport(
    layerId: "integrity",
    kind: slkIntegrity,
    mandatory: true,
    passed: false
  )

  if '\0' in ctx.manifestPath:
    result.findings.add(SecurityFinding(
      layerId: "integrity",
      code: "INTEGRITY_MANIFEST_INVALID_PATH",
      severity: sevError,
      subject: ctx.manifestPath,
      message: "❌ [INTEGRITY VIOLATION] Integrity manifest path contains prohibited NUL byte."
    ))
    return

  if ctx.manifestPath.len == 0 or dirExists(ctx.manifestPath) or not fileExists(ctx.manifestPath):
    result.findings.add(SecurityFinding(
      layerId: "integrity",
      code: "INTEGRITY_MANIFEST_MISSING",
      severity: sevError,
      subject: ctx.manifestPath,
      message: "❌ [INTEGRITY VIOLATION] Integrity manifest not found: " & ctx.manifestPath,
      hint: "Build the extension with `pgxtool build-extension` to generate <ext>.integrity.json."
    ))
    return

  var manifest: IntegrityManifest
  try:
    manifest = jsonToManifest(parseJson(readFile(ctx.manifestPath)))
  except CatchableError as e:
    result.findings.add(SecurityFinding(
      layerId: "integrity",
      code: "INTEGRITY_MANIFEST_INVALID",
      severity: sevError,
      subject: ctx.manifestPath,
      message: "❌ [INTEGRITY VIOLATION] Invalid integrity manifest (" & ctx.manifestPath & "): " & e.msg
    ))
    return

  if requireSignature or manifest.hmacSha256.len > 0:
    if expectedKey.len == 0:
      let msg =
        if requireSignature:
          "❌ [INTEGRITY VIOLATION] Signature verification required, but PGX_INTEGRITY_KEY is not set."
        else:
          "❌ [INTEGRITY VIOLATION] Manifest contains an HMAC-SHA256 signature, but PGX_INTEGRITY_KEY is not set."
      result.findings.add(SecurityFinding(
        layerId: "integrity",
        code: "INTEGRITY_KEY_MISSING",
        severity: sevError,
        subject: ctx.manifestPath,
        message: msg,
        hint: "Export PGX_INTEGRITY_KEY with the signing key used during build."
      ))
    elif manifest.hmacSha256.len == 0:
      result.findings.add(SecurityFinding(
        layerId: "integrity",
        code: "INTEGRITY_SIGNATURE_MISSING",
        severity: sevError,
        subject: ctx.manifestPath,
        message: "❌ [INTEGRITY VIOLATION] Signature verification required, but manifest is unsigned (empty hmacSha256).",
        hint: "Rebuild the extension with PGX_INTEGRITY_KEY set to sign the manifest."
      ))
    elif not verifyManifestSignature(manifest, expectedKey):
      result.findings.add(SecurityFinding(
        layerId: "integrity",
        code: "INTEGRITY_SIGNATURE_INVALID",
        severity: sevError,
        subject: ctx.manifestPath,
        message: "❌ [INTEGRITY VIOLATION] HMAC-SHA256 signature verification failed for " & ctx.manifestPath,
        hint: "Ensure PGX_INTEGRITY_KEY matches the signing key and the manifest was not tampered with."
      ))

  let artifactErrors = verifyDiskArtifacts(manifest, ctx.soPath, ctx.sqlPath, ctx.controlPath)
  for err in artifactErrors:
    result.findings.add(SecurityFinding(
      layerId: "integrity",
      code: "INTEGRITY_ARTIFACT_MISMATCH",
      severity: sevError,
      subject: ctx.manifestPath,
      message: "❌ [INTEGRITY VIOLATION] " & err,
      hint: "Rebuild and reinstall the extension cleanly without modifying artifacts on disk."
    ))

  result.passed = (result.findings.len == 0)

proc integritySecurityLayer*(expectedKey: string = "", requireSignature: bool = false): SecurityLayer =
  ## Constructs the mandatory Layer 3 integrity attestation security layer.
  let capturedKey = expectedKey
  let capturedRequireSig = requireSignature
  SecurityLayer(
    id: "integrity",
    kind: slkIntegrity,
    mandatory: true,
    check: proc(ctx: AuditContext): LayerReport =
      validateManifestAndArtifacts(ctx, capturedKey, capturedRequireSig)
  )
