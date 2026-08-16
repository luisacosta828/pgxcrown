# 📊 PostgreSQL Set Returning Functions (SETOF) Test Suite (`v0.15.0`)

This test suite verifies **v0.15.0 Set Returning Functions (SETOF)**. It guarantees that returning standard idiomatic Nim sequences (`seq[T]`) automatically generates PostgreSQL `RETURNS SETOF <type>` DDL manifests and executes via PostgreSQL's `FuncCallContext` state machine with zero GC memory leaks.

---

## 📋 Nim UDF Definitions (`tests/srf_suite/srf_test.nim`)

```nim
import pgxcrown

# 1. Primitive Integer Set Returning Function (seq[int32] -> RETURNS SETOF int4)
proc generate_series_nim*(startVal: int32, endVal: int32): seq[int32] =
  result = @[]
  for i in startVal .. endVal:
    result.add(i)

# 2. Primitive String Set Returning Function (seq[string] -> RETURNS SETOF text)
proc list_fruits*(): seq[string] =
  return @["Apple", "Banana", "Cherry", "Dragonfruit"]
```

---

## 📜 Generated SQL DDL Manifest (`srf_demo.sql`)

```sql
CREATE OR REPLACE FUNCTION generate_series_nim(int4, int4) RETURNS SETOF int4 AS
'srf_demo', 'pgx_generate_series_nim'
LANGUAGE c STRICT;

CREATE OR REPLACE FUNCTION list_fruits() RETURNS SETOF text AS
'srf_demo', 'pgx_list_fruits'
LANGUAGE c STRICT;
```

---

## 🧪 Interactive `psql` Verification Queries

```sql
-- 1. Test Primitive Integer Set Returning Function
SELECT * FROM generate_series_nim(1, 5);
/*
 generate_series_nim 
---------------------
                   1
                   2
                   3
                   4
                   5
(5 rows)
*/

-- 2. Test Primitive String Set Returning Function
SELECT * FROM list_fruits();
/*
  list_fruits  
-------------
 Apple
 Banana
 Cherry
 Dragonfruit
(4 rows)
*/
```
