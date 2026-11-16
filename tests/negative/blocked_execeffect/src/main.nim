import pgxcrown
import std/osproc

# Negative security fixture: must be rejected at compile time (ExecIOEffect)
proc unsafe_exec_cmd*(cmd: string): int32 =
  return execCmd($cmd).int32
