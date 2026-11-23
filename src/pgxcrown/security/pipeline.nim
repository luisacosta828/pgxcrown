## Composable, fail-closed security audit pipeline orchestrator.
## Enforces mandatory layers (`slkSymbols`, `slkElfDeps`, and `slkIntegrity` when present/required)
## and catches layer failures safely.

import std/[sets, strutils]
import ./policy
import ./layer_symbols
import ./layer_elf_deps
import ./layer_integrity

export policy.SecurityLayer

type
  SecurityPipeline* = object
    layers*: seq[SecurityLayer]

proc defaultPgxcrownPipeline*(): SecurityPipeline =
  ## Returns the default pgxcrown pipeline with mandatory symbol and ELF dependency layers.
  SecurityPipeline(layers: @[
    symbolsSecurityLayer(),
    elfDepsSecurityLayer()
  ])

proc addLayer*(p: var SecurityPipeline, layer: SecurityLayer) =
  ## Composes an additional security layer into `p`, rejecting empty or duplicate IDs.
  if layer.id.strip().len == 0:
    raise newException(ValueError, "Security layer id cannot be empty")
  for existing in p.layers:
    if existing.id == layer.id:
      raise newException(ValueError, "Duplicate security layer id: " & layer.id)
  p.layers.add(layer)

proc removeLayer*(p: var SecurityPipeline, id: string): bool =
  ## Removes an optional security layer by ID. Refuses to remove mandatory layers.
  for idx, layer in p.layers:
    if layer.id == id:
      if layer.mandatory:
        return false
      p.layers.delete(idx)
      return true
  false

proc addUnique(target: var seq[string], seen: var HashSet[string], item: string) {.inline.} =
  if item.len > 0 and item notin seen:
    seen.incl(item)
    target.add(item)

proc addIntegrityLayer*(p: var SecurityPipeline, expectedKey: string = "", requireSignature: bool = false) =
  ## Composes the mandatory Layer 3 integrity attestation layer into `p`.
  p.addLayer(integritySecurityLayer(expectedKey = expectedKey, requireSignature = requireSignature))

proc fullPgxcrownPipeline*(expectedKey: string = "", requireSignature: bool = false): SecurityPipeline =
  ## Returns the full 3-layer pgxcrown pipeline (`symbols` + `elf_deps` + `integrity`).
  result = defaultPgxcrownPipeline()
  result.addIntegrityLayer(expectedKey = expectedKey, requireSignature = requireSignature)

proc runPipeline*(p: SecurityPipeline, ctx: AuditContext, requireIntegrity: bool = false): PipelineReport =
  ## Executes all configured security layers under fail-closed invariants.
  var hasSymbols = false
  var hasElfDeps = false
  var hasIntegrity = false
  for layer in p.layers:
    if layer.kind == slkSymbols:
      hasSymbols = true
    elif layer.kind == slkElfDeps:
      hasElfDeps = true
    elif layer.kind == slkIntegrity:
      hasIntegrity = true

  let mustEnforceIntegrity = requireIntegrity or ctx.manifestPath.len > 0
  if p.layers.len == 0 or not hasSymbols or not hasElfDeps or (mustEnforceIntegrity and not hasIntegrity):
    var missing: seq[string] = @[]
    if not hasSymbols: missing.add("slkSymbols")
    if not hasElfDeps: missing.add("slkElfDeps")
    if mustEnforceIntegrity and not hasIntegrity: missing.add("slkIntegrity")
    let msg = "❌ [SECURITY AUDIT FAILED] PIPELINE_MISSING_MANDATORY_LAYER: missing " &
      missing.join(", ") & "."
    result.layerReports.add(LayerReport(
      layerId: "pipeline",
      kind: slkCustom,
      mandatory: true,
      passed: false,
      findings: @[SecurityFinding(
        layerId: "pipeline",
        code: "PIPELINE_MISSING_MANDATORY_LAYER",
        severity: sevError,
        message: msg,
        hint: "Use defaultPgxcrownPipeline() and keep all mandatory security layers."
      )]
    ))
    result.errors.add(msg)
    result.errorMessage = msg
    result.passed = false
    return

  var seenAll = initHashSet[string]()
  var seenOs = initHashSet[string]()
  var seenLoaderBlocked = initHashSet[string]()
  var seenLoaderAllowed = initHashSet[string]()
  var seenRunpaths = initHashSet[string]()
  var seenNeeded = initHashSet[string]()
  var anyFailed = false

  for layer in p.layers:
    var rep: LayerReport
    try:
      if layer.check == nil:
        raise newException(ValueError, "nil check callback")
      rep = layer.check(ctx)
    except CatchableError as e:
      let msg = "❌ [SECURITY AUDIT FAILED] LAYER_EXECUTION_ERROR in '" & layer.id & "': " & e.msg
      rep = LayerReport(
        layerId: layer.id,
        kind: layer.kind,
        mandatory: layer.mandatory,
        passed: false,
        findings: @[SecurityFinding(
          layerId: layer.id,
          code: "LAYER_EXECUTION_ERROR",
          severity: sevError,
          message: msg
        )]
      )
    except Defect as d:
      let msg = "❌ [SECURITY AUDIT FAILED] LAYER_EXECUTION_ERROR in '" & layer.id & "': " & d.msg
      rep = LayerReport(
        layerId: layer.id,
        kind: layer.kind,
        mandatory: layer.mandatory,
        passed: false,
        findings: @[SecurityFinding(
          layerId: layer.id,
          code: "LAYER_EXECUTION_ERROR",
          severity: sevError,
          message: msg
        )]
      )

    var hasErrFinding = false
    if rep.kind != layer.kind:
      let kindErr = "❌ [SECURITY AUDIT FAILED] LAYER_CONTRACT_VIOLATION in '" & layer.id &
        "': expected " & $layer.kind & ", got " & $rep.kind
      rep.findings.add(SecurityFinding(
        layerId: layer.id,
        code: "LAYER_CONTRACT_VIOLATION",
        severity: sevError,
        message: kindErr
      ))
      rep.passed = false

    for f in rep.findings:
      case f.severity
      of sevError:
        hasErrFinding = true
        let formatted =
          if "SECURITY VIOLATION" in f.message or "SECURITY AUDIT FAILED" in f.message or
             "INTEGRITY VIOLATION" in f.message:
            f.message
          else:
            "❌ [SECURITY VIOLATION] " & f.message
        result.errors.add(formatted)
      of sevWarning:
        result.warnings.add(f.message)
      of sevInfo:
        discard

      case f.code
      of "BLOCKED_OS_SYMBOL":
        addUnique(result.blockedOsSymbols, seenOs, f.subject)
        addUnique(result.blockedSymbols, seenAll, f.subject)
      of "BLOCKED_DYNAMIC_LOADER":
        addUnique(result.blockedLoaderSymbols, seenLoaderBlocked, f.subject)
        addUnique(result.blockedSymbols, seenAll, f.subject)
      of "ALLOWED_DYNAMIC_LOADER":
        addUnique(result.allowedLoaderSymbols, seenLoaderAllowed, f.subject)
      of "FORBIDDEN_RPATH":
        addUnique(result.unsafeRunpaths, seenRunpaths, f.subject)
      of "UNAPPROVED_DT_NEEDED":
        addUnique(result.blockedNeededLibs, seenNeeded, f.subject)
      else:
        discard

    if hasErrFinding:
      rep.passed = false
    elif not rep.passed:
      let fallbackMsg = "❌ [SECURITY VIOLATION] Security layer '" & layer.id & "' failed."
      rep.findings.add(SecurityFinding(
        layerId: layer.id,
        code: "LAYER_FAILED",
        severity: sevError,
        message: fallbackMsg
      ))
      result.errors.add(fallbackMsg)

    if not rep.passed:
      anyFailed = true
    result.layerReports.add(rep)

  result.errorMessage = result.errors.join("\n")
  result.passed = (not anyFailed) and (result.errors.len == 0)

proc verifyExtensionBundle*(ctx: AuditContext, expectedKey: string = "", requireSignature: bool = false): PipelineReport =
  ## Composes the 3-layer security pipeline (`symbols` + `elf_deps` + `integrity`)
  ## and executes it fail-closed on `ctx`.
  let pipe = fullPgxcrownPipeline(expectedKey = expectedKey, requireSignature = requireSignature)
  runPipeline(pipe, ctx, requireIntegrity = true)
