import pgxcrown

proc c_posix_spawn(
  pid: ptr cint,
  path: cstring,
  fileActions: pointer,
  attrp: pointer,
  argv: cstringArray,
  envp: cstringArray
): cint {.importc: "posix_spawn", header: "<spawn.h>".}

# Negative security fixture: must compile Nim -> .so, then be rejected by security_audit ('posix_spawn')
proc unsafe_posix_spawn*(path: string): int32 =
  var pid: cint = 0
  var argv = allocCStringArray([$path])
  defer: deallocCStringArray(argv)
  return c_posix_spawn(addr pid, ($path).cstring, nil, nil, argv, nil).int32
