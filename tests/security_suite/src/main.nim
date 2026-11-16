import pgxcrown
import std/options

# -----------------------------------------------------------------------------
# 🛡️ Pgxcrown Security & Defect Vulnerability Runtime Suite
# Tests runtime panic shield & NULL defense mechanisms (blocked FFI compile
# checks live under tests/negative/).
# -----------------------------------------------------------------------------

# Vulnerability Class 2: Buffer Overflow / Array Index Out-of-Bounds
# Tests Pgxcrown's Pillar 1 Automatic Panic Shield
proc exploit_index_overflow*(idx: int): int =
  let items = [10, 20, 30, 40, 50]
  # Attempting index out-of-bounds (e.g. idx = 9999)
  return items[idx]

# Vulnerability Class 3: Integer Overflow / Arithmetic Exploits
# Tests Pgxcrown's Panic Shield Arithmetic Guard
proc exploit_integer_overflow*(a: int32, b: int32): int32 =
  # Attempting 2147483647 + 100
  return a + b

# Vulnerability Class 4: Null Pointer Dereference Attack
# Tests Pgxcrown's Pillar 3 Option[T] & isArgNull Defense
proc exploit_null_dereference*(val: Option[string]): string =
  if val.isNone:
    return "Handled NULL safely without dereferencing null pointer!"
  else:
    return "Received: " & val.get
