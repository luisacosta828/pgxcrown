import pgxcrown
import std/strutils

# -----------------------------------------------------------------------------
# 🔢 PostgreSQL Array (seq[T]) Test Suite for v0.13.2
# Supports primitive arrays (int4[], text[], bool[]) and composite arrays (record[])!
# -----------------------------------------------------------------------------

# Test 1: Sum Integer Array (int4[])
proc sum_int_array*(numbers: seq[int32]): int32 =
  var total: int32 = 0
  for n in numbers:
    total += n
  return total

# Test 2: Double Integer Array (returns int4[])
proc double_int_array*(numbers: seq[int32]): seq[int32] =
  result = newSeq[int32](numbers.len)
  for i in 0 ..< numbers.len:
    result[i] = numbers[i] * 2

# Test 3: Concat String Array (text[] -> Text)
proc join_string_array*(words: seq[string], sep: string): string =
  return words.join(sep)

# Test 4: Transform String Array (text[] -> text[])
proc uppercase_string_array*(words: seq[string]): seq[string] =
  result = newSeq[string](words.len)
  for i in 0 ..< words.len:
    result[i] = words[i].toUpperAscii

# Test 5: Boolean Array Filter (bool[] -> int4)
proc count_true_bools*(flags: seq[bool]): int32 =
  var count: int32 = 0
  for flag in flags:
    if flag: count += 1
  return count

# Test 6: Composite Object Array (record[] -> int4)
type
  Person* = object
    age*: int32
    name*: string

proc count_adults*(people: seq[Person]): int32 =
  var count: int32 = 0
  for p in people:
    if p.age >= 18:
      count += 1
  return count
