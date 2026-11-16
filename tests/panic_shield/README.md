# 🛡️ Pgxcrown Panic Shield & Safety Verification Suite

This test suite proves **Pgxcrown's** crash-proof safety guarantees when running Nim code inside PostgreSQL backend worker processes.

All functions exported via Pgxcrown are automatically shielded against unhandled defects and runtime exceptions. Rather than causing process termination (`SIGABRT`), panics are intercepted at runtime and converted into PostgreSQL `ereport(ERROR, ...)` transaction aborts.

---

## 📋 Verification Test Suite

### 1. Integer Overflow Protection (`proof_integer_overflow`)
Proves that arithmetic overflow (e.g. `2,147,483,647 + 1`) triggers `OverflowDefect` and is safely caught as a SQL error.

```sql
-- Triggers OverflowDefect (a + b > INT32_MAX)
SELECT proof_integer_overflow(2147483647, 1);

-- Expected Output:
-- ERROR:  Extension Defect [OverflowDefect]: over- or underflow
```

---

### 2. Array / Sequence Bounds Protection (`proof_index_out_of_bounds`)
Proves that out-of-bounds array or sequence indexing triggers `IndexDefect` and is safely caught.

```sql
-- Sequence has 3 elements (indices 0..2). Accessing index 5 triggers IndexDefect.
SELECT proof_index_out_of_bounds(5);

-- Expected Output:
-- ERROR:  Extension Defect [IndexDefect]: index 5 not in 0 .. 2
```

---

### 3. Value Conversion Protection (`proof_value_conversion`)
Proves that invalid string-to-number parsing triggers `ValueError` and is safely caught.

```sql
-- Passing an unparseable integer string triggers ValueError.
SELECT proof_value_conversion('invalid_number');

-- Expected Output:
-- ERROR:  Extension Error [ValueError]: invalid integer: invalid_number
```

---

### 4. Range Boundary Constraint Protection (`proof_range_boundary`)
Proves that subrange constraint violations (e.g. `range[1..100]`) trigger `RangeDefect` and are safely caught.

```sql
-- Subrange type is constrained to 1..100. Passing 500 triggers RangeDefect.
SELECT proof_range_boundary(500);

-- Expected Output:
-- ERROR:  Extension Defect [RangeDefect]: value out of range
```

---

### 5. Safe Null-Datum Handling (`proof_null_datum`)
Proves that empty or NULL string datums are handled safely without pointer dereference errors.

```sql
SELECT proof_null_datum('');

-- Expected Output:
-- Handled NULL/Empty string datum safely!
```

---

## 🛠️ How to Run the Tests

Run directly via the multi-version Docker/GHCR test runner (PostgreSQL 14–17):
```bash
pgxtool test tests/panic_shield --all
```

Source lives in [`src/main.nim`](src/main.nim), deterministic SQL regression tests in [`tests/sql/01_panic_shield.sql`](tests/sql/01_panic_shield.sql), and expected outputs in [`tests/expected/01_panic_shield.out`](tests/expected/01_panic_shield.out).

---

## 🎯 Verification Result

- **Backend Process Stability**: 100% Operational (0 crashes / 0 process terminations).
- **Transaction Safety**: All defects result in clean SQL transaction aborts (`ereport(ERROR)`).
