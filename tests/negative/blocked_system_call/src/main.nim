import pgxcrown

proc c_system(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}

# Negative security fixture: must compile Nim -> .so, then be rejected by auditBinarySymbols
proc unsafe_system_call*(cmd: string): int32 =
  return c_system(($cmd).cstring).int32
