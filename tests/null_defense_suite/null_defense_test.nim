import pgxcrown
import std/options

# 1. Non-STRICT Null-Safe String Parameter (string -> string)
proc safe_greet*(name: string): string =
  if name.len == 0:
    return "Hello Anonymous!"
  return "Hello " & name & "!"

# 2. Non-STRICT Null-Safe Integer Sum (int32, int32 -> int32)
proc safe_add*(a: int32, b: int32): int32 =
  return a + b

# 3. Non-STRICT Null-Safe Array Processing (seq[int32] -> int32)
proc safe_sum_array*(numbers: seq[int32]): int32 =
  var total: int32 = 0
  for n in numbers:
    total += n
  return total

# 4. Option[int32] Parameter Defense (Option[int32] -> int32)
proc option_add*(a: int32, b: Option[int32]): int32 =
  if b.isNone:
    return a
  return a + b.get
