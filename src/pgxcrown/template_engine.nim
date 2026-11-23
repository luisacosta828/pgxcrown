## =============================================================================
## Pgxcrown Project Template Engine (Backwards-Compatible Facade)
## =============================================================================
## Re-exports the modular `pgxcrown/scaffolding/` subsystem so existing callers
## and unit tests importing `pgxcrown/template_engine` continue working seamlessly.
## =============================================================================

import ./scaffolding/[regex_lite, manifest, registry, renderer]
export regex_lite, manifest, registry, renderer
