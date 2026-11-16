import pgxcrown
import std/options

# -----------------------------------------------------------------------------
# 🛡️ Pgxcrown v0.13.0: Default Parameters & NULL Defense Test Suite
# Target: PostgreSQL 14
# -----------------------------------------------------------------------------

# Test 1: Default String and Int parameters in SQL DDL
proc test_default_params*(name: string = "World", count: int = 1): string =
  return "Hello " & name & " x" & $count

# Test 2: Default Boolean parameter
proc test_default_bool*(flag: bool = true): string =
  if flag:
    return "Flag is ON"
  else:
    return "Flag is OFF"

# Test 3: Option[T] parameter (handles NULL safely)
proc test_option_param*(a: int, b: Option[int]): int =
  if b.isNone:
    return a
  else:
    return a + b.get

# Test 4: Option[T] return type (returns SQL NULL when none)
proc test_option_return*(val: int): Option[int] =
  if val < 0:
    return none(int)
  else:
    return some(val * 2)

# Test 5: Combined Option and Default parameters
proc test_option_and_default*(x: int, opt: Option[string] = none(string)): string =
  if opt.isSome:
    return "Val: " & $x & " Opt: " & opt.get
  else:
    return "Val: " & $x & " Opt: NULL"
