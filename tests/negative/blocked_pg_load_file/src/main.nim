import pgxcrown

proc c_load_file(filename: cstring, restricted: bool) {.importc: "load_file", header: "fmgr.h".}

# Negative security fixture: must compile Nim -> .so, then be rejected by security_audit ('load_file')
proc unsafe_pg_load_file*(path: string): bool =
  c_load_file(($path).cstring, true)
  return true
