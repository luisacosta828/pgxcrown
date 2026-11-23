import pgxcrown
import std/dynlib

# Negative security fixture: std/dynlib (dlopen/dlsym/dlclose) must be blocked by default
proc check_dlopen_default*(libPath: string, symName: string): bool =
  let h = loadLib($libPath)
  if h == nil:
    return false
  let p = symAddr(h, ($symName).cstring)
  unloadLib(h)
  return p != nil
