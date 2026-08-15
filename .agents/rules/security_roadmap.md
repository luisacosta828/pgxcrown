# 🛡️ Pgxcrown Security & Architecture Roadmap

This rule file records project progress, security pillars, and execution workflow rules for `pgxcrown`.

## 📌 Project Status Overview

- **Current Version**: `v0.12.0`
- **Main Branch**: `master`
- **Branching Rule**: Every feature must be built on its own dedicated feature branch (`feature/<name>`) before merging to `master`.

---

## 🎯 Security Pillars Status

### ✅ Pillar 1: Automatic Panic & Exception Shield (COMPLETED - v0.12.0)
- **Branch**: `feature/automatic-panic-shield` (Merged to `master`)
- **Key Changes**:
  - Automatically wraps all exported `pgx` procedures in `try ... except Defect ... except CatchableError` at compile time.
  - Converts panics (`OverflowDefect`, `IndexDefect`, `NilAccessDefect`, `RangeDefect`, `ValueError`) into PostgreSQL `ereport(ERROR, ...)` transaction aborts without backend process crashes (`0 SIGABRT`).
  - Fixed `reportError` FFI C-string emission to pass `cstring(msg)` instead of Nim string structs.
  - Added test suite in `tests/panic_shield/panic_shield_test.nim` and `tests/panic_shield/README.md`.
  - Updated `README.md` and GitHub Pages glassmorphism showcase website in `docs/`.

---

### ⏳ Pillar 3: Null-Pointer & Null-Datum Defense (NEXT UP)
- **Target Branch**: `feature/null-pointer-defense`
- **Target File**: `src/pgxcrown/datatypes/basic.nim`
- **Goal**:
  - Add explicit `PG_ARGISNULL(n)` and `nil` checks in parameter extraction and converters.
  - Prevent null-pointer dereference segfaults when SQL `NULL` arguments are passed to functions without `STRICT`.

---

### ⏳ Pillar 4: Shell Execution Hardening (PENDING)
- **Target Branch**: `feature/shell-hardening`
- **Target File**: `src/pgxcrown/pgxtool.nim`
- **Goal**:
  - Harden all `execShellCmd` / system invocations with `quoteShell` to eliminate command injection vectors in `pgxtool`.

---

## 🛠️ Developer Workflow & Commands

### Building Extensions with `pgxtool`
```bash
pgxtool build-extension linux_test
sudo ./linux_test/src/install.sh
sudo systemctl restart postgresql
```

### Safety Test Commands (`psql`)
```bash
psql -U postgres -c "SELECT proof_integer_overflow(2147483647, 1);"
psql -U postgres -c "SELECT proof_index_out_of_bounds(5);"
psql -U postgres -c "SELECT proof_value_conversion('invalid_number');"
psql -U postgres -c "SELECT proof_range_boundary(500);"
psql -U postgres -c "SELECT proof_null_datum('');"
```
