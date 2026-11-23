## Layer 0: Immutable contract types and data structures for pgxcrown's layered security pipeline.
## Pure stdlib only; static musl-gcc compatible.

type
  SecuritySeverity* = enum
    sevInfo
    sevWarning
    sevError

  SecurityLayerKind* = enum
    slkSymbols
    slkElfDeps
    slkIntegrity
    slkCustom

  SecurityFinding* = object
    layerId*: string
    code*: string
    severity*: SecuritySeverity
    message*: string
    hint*: string
    subject*: string = ""

  LayerReport* = object
    layerId*: string
    kind*: SecurityLayerKind
    mandatory*: bool
    passed*: bool
    findings*: seq[SecurityFinding]

  SecurityAuditPolicy* = object
    ## Security audit policy controlling optional exemptions such as dynamic loading.
    allowDynamicLoader*: bool = false

  AuditContext* = object
    soPath*: string
    projectDir*: string
    policy*: SecurityAuditPolicy
    sqlPath*: string
    controlPath*: string
    manifestPath*: string

  SecurityLayer* = object
    id*: string
    kind*: SecurityLayerKind
    mandatory*: bool
    check*: proc(ctx: AuditContext): LayerReport

  PipelineReport* = object
    passed*: bool
    layerReports*: seq[LayerReport]
    errors*: seq[string]
    warnings*: seq[string]
    errorMessage*: string
    blockedSymbols*: seq[string]
    blockedOsSymbols*: seq[string]
    blockedLoaderSymbols*: seq[string]
    allowedLoaderSymbols*: seq[string]
    unsafeRunpaths*: seq[string]
    blockedNeededLibs*: seq[string]

proc blockedNeededLibraries*(r: PipelineReport): seq[string] {.inline.} =
  ## Convenience accessor matching `blockedNeededLibs`.
  r.blockedNeededLibs
