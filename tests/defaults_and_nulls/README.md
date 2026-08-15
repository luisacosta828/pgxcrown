# 🛡️ Pgxcrown v0.13.0: Default Parameters & Option[T] NULL Defense Suite

Targeting **PostgreSQL 14**, this test suite verifies:
1. Bidirectional conversion of optional values via Nim's `Option[T]` (`std/options`).
2. Automatic extraction of SQL `NULL`s via `PG_ARGISNULL` without backend crashes.
3. Safe emission of PostgreSQL `DEFAULT` parameter clauses in generated `.sql` DDL.
4. Omission of `STRICT` (`language c;`) for defaulted or optional functions, enabling `CALLED ON NULL INPUT` semantics in PostgreSQL.

---

## 📋 Nim Source Procedures (`tests/defaults_and_nulls/defaults_nulls_test.nim`)

```nim
import pgxcrown
import std/options

proc greet*(name: string = "World", count: int = 1): string =
  return "Hello " & name & " x" & $count

proc test_default_bool*(flag: bool = true): string =
  if flag: "Flag is ON" else: "Flag is OFF"

proc test_option_param*(a: int, b: Option[int]): int =
  if b.isNone: a else: a + b.get

proc test_option_return*(val: int): Option[int] =
  if val < 0: none(int) else: some(val * 2)

proc test_option_and_default*(x: int, opt: Option[string] = none(string)): string =
  if opt.isSome: "Val: " & $x & " Opt: " & opt.get
  else: "Val: " & $x & " Opt: NULL"
```

---

## 📜 Generated PostgreSQL SQL DDL

```sql
CREATE OR REPLACE FUNCTION greet(Text DEFAULT 'World', int4 DEFAULT 1) returns Text as
'v013_demo', 'pgx_greet'
language c;

CREATE OR REPLACE FUNCTION test_default_bool(boolean DEFAULT true) returns Text as
'v013_demo', 'pgx_test_default_bool'
language c;

CREATE OR REPLACE FUNCTION test_option_param(int4, int4 DEFAULT NULL) returns int4 as
'v013_demo', 'pgx_test_option_param'
language c;

CREATE OR REPLACE FUNCTION test_option_return(int4) returns int4 as
'v013_demo', 'pgx_test_option_return'
language c;

CREATE OR REPLACE FUNCTION test_option_and_default(int4, Text DEFAULT NULL) returns Text as
'v013_demo', 'pgx_test_option_and_default'
language c;
```

---

## 🧪 Interactive `psql` Verification Queries

```sql
-- 1. Default Parameters
SELECT greet();
-- Output: "Hello World x1"

SELECT greet('Nim Developer', 5);
-- Output: "Hello Nim Developer x5"

SELECT test_default_bool();
-- Output: "Flag is ON"

-- 2. Option[T] Input & NULL Handling
SELECT test_option_param(42, NULL);
-- Output: 42

SELECT test_option_param(42, 8);
-- Output: 50

-- 3. Option[T] Return (SQL NULL on none(int))
SELECT test_option_return(-5);
-- Output: NULL

SELECT test_option_return(10);
-- Output: 20

-- 4. Combined Option and Default Parameters
SELECT test_option_and_default(100);
-- Output: "Val: 100 Opt: NULL"

SELECT test_option_and_default(100, 'Pgxcrown');
-- Output: "Val: 100 Opt: Pgxcrown"
```
