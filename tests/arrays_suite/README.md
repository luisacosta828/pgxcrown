# 🔢 PostgreSQL Dynamic Array (`seq[T]`) & Composite Record Array (`seq[Object]` / `seq[Tuple]`) Test Suite (`v0.13.2`)

This test suite verifies bidirectional zero-copy array mapping between **Nim sequences** (`seq[T]`) and **PostgreSQL dynamic primitive arrays** (`int4[]`, `int8[]`, `float8[]`, `text[]`, `bool[]`) as well as **PostgreSQL composite record arrays** (`record[]`).

---

## 📋 Nim UDF Definitions (`tests/arrays_suite/arrays_test.nim`)

```nim
import pgxcrown
import std/strutils

# 1. Sum Integer Array (int4[] -> int4)
proc sum_int_array*(numbers: seq[int32]): int32 =
  var total: int32 = 0
  for n in numbers:
    total += n
  return total

# 2. Double Integer Array (int4[] -> int4[])
proc double_int_array*(numbers: seq[int32]): seq[int32] =
  userResult = newSeq[int32](numbers.len)
  for i in 0 ..< numbers.len:
    userResult[i] = numbers[i] * 2

# 3. Join String Array (text[], text -> Text)
proc join_string_array*(words: seq[string], sep: string): string =
  return words.join(sep)

# 4. Transform String Array (text[] -> text[])
proc uppercase_string_array*(words: seq[string]): seq[string] =
  userResult = newSeq[string](words.len)
  for i in 0 ..< words.len:
    userResult[i] = words[i].toUpperAscii

# 5. Count True Booleans (bool[] -> int4)
proc count_true_bools*(flags: seq[bool]): int32 =
  var count: int32 = 0
  for flag in flags:
    if flag: count += 1
  return count

# 6. Composite Object Array (record[] -> int4)
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
```

---

## 📜 Generated PostgreSQL SQL DDL (`arrays_demo.sql`)

```sql
CREATE OR REPLACE FUNCTION sum_int_array(int4[]) returns int4 as
'arrays_demo', 'pgx_sum_int_array'
language c strict;

CREATE OR REPLACE FUNCTION double_int_array(int4[]) returns int4[] as
'arrays_demo', 'pgx_double_int_array'
language c strict;

CREATE OR REPLACE FUNCTION join_string_array(text[], Text) returns Text as
'arrays_demo', 'pgx_join_string_array'
language c strict;

CREATE OR REPLACE FUNCTION uppercase_string_array(text[]) returns text[] as
'arrays_demo', 'pgx_uppercase_string_array'
language c strict;

CREATE OR REPLACE FUNCTION count_true_bools(bool[]) returns int4 as
'arrays_demo', 'pgx_count_true_bools'
language c strict;

CREATE OR REPLACE FUNCTION count_adults(record[]) returns int4 as
'arrays_demo', 'pgx_count_adults'
language c strict;
```

---

## 🧪 Interactive `psql` Verification Queries

```sql
-- 1. Test Integer Array Summation
SELECT sum_int_array(ARRAY[10, 20, 30, 40]);
-- Result: 100

-- 2. Test Integer Array Transformation
SELECT double_int_array(ARRAY[1, 2, 3, 4, 5]);
-- Result: {2, 4, 6, 8, 10}

-- 3. Test String Array Joining
SELECT join_string_array(ARRAY['PostgreSQL', 'Nim', 'Pgxcrown'], ' 👑 ');
-- Result: "PostgreSQL 👑 Nim 👑 Pgxcrown"

-- 4. Test String Array Transformation
SELECT uppercase_string_array(ARRAY['alpha', 'beta', 'gamma']);
-- Result: {"ALPHA", "BETA", "GAMMA"}

-- 5. Test Boolean Array Filtering
SELECT count_true_bools(ARRAY[true, false, true, true, false]);
-- Result: 3

-- 6. Test Composite Record Array
SELECT count_adults(ARRAY[(25, 'Alice')::record, (15, 'Bob')::record, (30, 'Charlie')::record]);
-- Result: 2
```
