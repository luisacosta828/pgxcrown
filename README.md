# Pgxcrown

Build Native, High-Performance Postgres Extensions in Nim.

![](banner.jpg)

**Pgxcrown** is an open-source framework and toolchain for building native [PostgreSQL](https://www.postgresql.org/) extensions in [Nim](https://nim-lang.org/). It combines Nim's expressive syntax and zero-overhead performance with PostgreSQL's C extension architecture (`postgres.h`, `fmgr.h`).

---

## 📊 Summary of Features

| Feature Area | Supported Capabilities | Details |
| :--- | :--- | :--- |
| **Extension Packaging** | `.control`, `--0.0.1.sql`, `install.sh` | Generates standard PostgreSQL extension control files and privileged installation scripts. |
| **Extension Enablement** | `CREATE EXTENSION <name>` | Load extensions directly using PostgreSQL's standard extension mechanism. |
| **Compile-Time Safety** | `{.trusted.}` pragma, Effect Tracking | Enforces IO-effect safety and controlled exception handling at compile time. |
| **Primitive Datatypes** | `int`, `int32`, `int64`, `float`, `string`, `cstring`, `bool` | Automatic bidirectional conversion between Nim native types and Postgres `Datum`. |
| **Enum Types** | Consuming Postgres `ENUM` in Nim | Auto-generates `CREATE TYPE ... AS ENUM` and converts Postgres OIDs to Nim enums. |
| **Composite Records** | Consuming Postgres `record` / `tuple` | Inspect and read PostgreSQL `HeapTupleHeader` attributes via Nim `tuple` and `object` types. |
| **Postgres Engine Hooks** | `emit_log`, `post_parse_analyze` | Intercept query parsing and log emission via built-in hook builders. |
| **CLI Tool (`pgxtool`)** | `init`, `create-project`, `build-extension`, `install`, `path-finders`, `test` | Scaffolding, path discovery, compilation, installation scripts, and Docker test harness. |

---

## 🛡️ Compile-Time Safety & the `trusted` Pragma

Pgxcrown leverages Nim's static effect tracking system to guarantee extension safety at compile-time via the `trusted` pragma:

```nim
{.pragma: trusted, raises: [ValueError], forbids: [IOEffect], tags: [].}
```

### Key Safety Guarantees:
1. **🚫 `forbids: [IOEffect]` (No Unchecked I/O Effects)**:
   Nim statically analyzes functions compiled by Pgxcrown. Any function marked or wrapped by Pgxcrown **cannot perform unhandled I/O operations** (such as raw file access, socket connections, or unhandled disk operations). Attempts to invoke unhandled I/O trigger a **static compiler error** before the extension binary is ever built.
2. **🏷️ `tags: []` (Pure / Effect-Free Execution)**:
   Ensures extension code executes without untracked side-effects on PostgreSQL backend memory or process state.
3. **⚠️ `raises: [ValueError]` (Controlled Exception Boundary)**:
   Prevents unhandled Nim exceptions from escaping across the C/Nim FFI boundary, preventing backend server crashes or unexpected process aborts.

---

## 🛠️ Prerequisites

- **PostgreSQL** (with CLI tools `pg_config` and header files `postgres.h`)
- **Nim Compiler** (`nim >= 2.0.0`)

---

## 🚀 Quickstart

### 1. Install Pgxcrown

```bash
nimble install pgxcrown
```

### 2. Initialize & Scaffold a Project

```bash
pgxtool init
pgxtool create-project myextension
```

### 3. Write Nim Extension Logic (`src/main.nim`)

Edit `src/main.nim` inside your initialized project directory:

```nim
proc add_numbers*(a: int, b: int): int =
  a + b

proc greet*(name: string): string =
  "Hello from Nim, " & name & "!"
```

### 4. Build & Install Extension

```bash
# Build the dynamic library, control file, and install script
pgxtool build-extension myextension

# Install files into PostgreSQL directories using the generated install script
sudo /path/to/myextension/src/install.sh
```

### 5. Enable in PostgreSQL (`psql`)

```sql
CREATE EXTENSION myextension;

SELECT add_numbers(10, 32);  -- Returns: 42
SELECT greet('PostgreSQL');   -- Returns: "Hello from Nim, PostgreSQL!"
```

---

## 💡 Code Examples & Data Type Usage

### 1. Basic Functions & Scalar Types

Scalar arguments and return values map cleanly to PostgreSQL SQL types:

```nim
proc multiply_float*(a: float, b: float): float =
  a * b

proc is_even*(val: int): bool =
  val mod 2 == 0
```

Generated SQL output:
```sql
CREATE OR REPLACE FUNCTION multiply_float(float4,float4) returns float4 as
'myextension', 'pgx_multiply_float'
language c strict;
```

---

### 2. Consuming Custom Enum Types

Define a Nim `enum` to consume custom PostgreSQL enum parameters:

```nim
type Status* = enum
  Active, Inactive, Pending

proc status_code*(s: Status): int =
  case s
  of Active: 1
  of Inactive: 2
  of Pending: 3
```

Generated SQL output:
```sql
CREATE TYPE Status AS ENUM ('Active','Inactive','Pending','PgxUnknownValue');

CREATE OR REPLACE FUNCTION status_code(Status) returns int4 as
'myextension', 'pgx_status_code'
language c strict;
```

---

### 3. Consuming Records & Composite Types

Nim `tuple` and `object` definitions can accept PostgreSQL `record` parameters:

```nim
type UserRecord* = object
  id: int
  name: string

proc process_user*(u: UserRecord): string =
  "Processed user ID " & $u.id
```

Generated SQL output:
```sql
CREATE OR REPLACE FUNCTION process_user(record) returns Text as
'myextension', 'pgx_process_user'
language c strict;
```

*Note: Currently composite objects and tuples can be consumed as input parameters. Returning composite types is planned for a future release.*

---

### 4. Postgres Hooks (`post_parse_analyze` & `emit_log`)

Scaffold dedicated PostgreSQL hooks to intercept engine execution stages:

```bash
# Scaffold a logging hook project
pgxtool create-hook emit_log
pgxtool build-extension emit_log
```

---

## 💻 `pgxtool` CLI Reference

| Command | Usage | Description |
| :--- | :--- | :--- |
| `init` | `pgxtool init` | Initializes local `pgxtool` working directory and config file. |
| `create-project` | `pgxtool create-project <name>` | Scaffolds a new extension project directory and `main.nim`. |
| `build-extension` | `pgxtool build-extension <name>` | Compiles Nim into `.so`/`.dll`, generates `.control`, `--0.0.1.sql`, and `install.sh`. |
| `install` | `pgxtool install <name>` | Generates the `install.sh` script and prints `sudo` execution instructions. |
| `create-type` | `pgxtool create-type <name> --base-type <type>` | Generates a custom datatype template for domain mapping. |
| `create-hook` | `pgxtool create-hook <hook_name>` | Scaffolds a Postgres engine hook extension (`emit_log`, `post_parse_analyze`). |
| `path-finders` | `pgxtool path-finders` | Resolves PostgreSQL system paths (`pg_config`, `libdir`, `includedir`, `sharedir`, `extension`). |
| `test` | `pgxtool test <name>` | Spins up a Docker container with PostgreSQL to mount and test the extension. |

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request or open an Issue to discuss proposed changes or features.

---

## 📜 License

[MIT](https://choosealicense.com/licenses/mit/)
