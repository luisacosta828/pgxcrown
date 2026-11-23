## Backward-compatible facade over the layered pgxcrown security pipeline (`pgxcrown/security/`).
## Pure stdlib only; compiles statically with `musl-gcc --passL:-static` as part of `pgxtool`.

import ./security/[policy, layer_symbols, layer_elf_deps, pipeline]
export policy, layer_symbols, layer_elf_deps, pipeline

type
  AuditResult* = PipelineReport

proc auditBinaryFile*(soPath: string, policy: SecurityAuditPolicy): AuditResult =
  ## Runs the mandatory pgxcrown security pipeline (`symbols` + `elf_deps`) against `soPath`.
  let ctx = AuditContext(
    soPath: soPath,
    policy: policy
  )
  runPipeline(defaultPgxcrownPipeline(), ctx)
