import pgxcrown

# -----------------------------------------------------------------------------
# 📊 v0.15.0 Set Returning Functions (SETOF) Test Suite
# Returning native Nim sequences (seq[T]) automatically emits RETURNS SETOF <type>!
# -----------------------------------------------------------------------------

# 1. Primitive Integer Set Returning Function (seq[int32] -> RETURNS SETOF int4)
proc generate_series_nim*(startVal: int32, endVal: int32): seq[int32] =
  result = @[]
  for i in startVal .. endVal:
    result.add(i)

# 2. Primitive String Set Returning Function (seq[string] -> RETURNS SETOF text)
proc list_fruits*(): seq[string] =
  return @["Apple", "Banana", "Cherry", "Dragonfruit"]
