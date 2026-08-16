# 🛡️ PostgreSQL Non-STRICT Null-Datum Defense Test Suite (`v0.14.0`)

This test suite verifies **v0.14.0 Non-STRICT Null-Datum Defense**. It guarantees that when PostgreSQL functions are executed on SQL `NULL` inputs (without `STRICT` mode), parameter extraction safely intercepts `isArgNull(n)` and provides default zero-values (`""`, `0`, `@[]`, `none(T)`) without backend process crashes (`0 SEGV / SIGABRTs`).

---

## 📋 Nim UDF Definitions (`tests/null_defense_suite/null_defense_test.nim`)

```nim
import pgxcrown
import std/options

# 1. Null-Safe String Parameter (string -> string)
proc safe_greet*(name: string): string =
  if name.len == 0:
    return "Hello Anonymous!"
  return "Hello " & name & "!"

# 2. Null-Safe Integer Addition (int32, int32 -> int32)
proc safe_add*(a: int32, b: int32): int32 =
  return a + b

# 3. Null-Safe Array Processing (seq[int32] -> int32)
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
```

---

## 🧪 Interactive `psql` Verification Queries

```sql
-- 1. Test Null String Parameter Handling
SELECT safe_greet(NULL);
-- Result: "Hello Anonymous!"

-- 2. Test Null Integer Addition
SELECT safe_add(10, NULL);
-- Result: 10

-- 3. Test Null Array Processing
SELECT safe_sum_array(NULL);
-- Result: 0

-- 4. Test Option[int32] Parameter Handling
SELECT option_add(25, NULL);
-- Result: 25
```
