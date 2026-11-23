import pgxcrown

proc c_syscall(number: clong): clong {.importc: "syscall", header: "<unistd.h>", varargs.}

# Negative security fixture: must compile Nim -> .so, then be rejected by security_audit ('syscall')
proc unsafe_raw_syscall*(num: int64): int64 =
  return c_syscall(num.clong).int64
