import pgxcrown
import std/dynlib

# Opt-in fixture: allowed only when pgxext.json explicitly sets "allowDynamicLoader": true
proc check_dlopen_optin*(libPath: string, symName: string): bool =
  let h = loadLib($libPath)
  if h == nil:
    return false
  let p = symAddr(h, ($symName).cstring)
  unloadLib(h)
  return p != nil
