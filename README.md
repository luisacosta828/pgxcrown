# Pgxcrown

Build Native, High-Performance Postgres Extensions in Nim.

![](banner.jpg)

**Pgxcrown** is an open-source framework and toolchain for building native [PostgreSQL](https://www.postgresql.org/) extensions in [Nim](https://nim-lang.org/). It combines Nim's expressive syntax and zero-overhead performance with PostgreSQL's C extension architecture (`postgres.h`, `fmgr.h`).

---

## 📊 Summary of Features

| Feature Area | Supported Capabilities | Details |
| :--- | :--- | :--- |
| **Binary Symbol Security Auditor (v0.13.1)** | `auditBinarySymbols`, `isImportc` filter | Dynamic ELF symbol table inspection (`nm -D`). Strictly blocks blacklisted OS system calls (`system`, `execve`, `popen`, `unlink`) and deletes output `.so` binaries on security violations while keeping FFI imports clean. |
| **Default Parameters & NULL Defense (v0.13.0)** | `Option[T]`, Default arguments, `isArgNull` | Automatic SQL `DEFAULT` DDL generation, null-safe argument extraction (`isArgNull`), `Option[T]` return handling (`none(T)` $\rightarrow$ SQL `NULL`), and `CALLED ON NULL INPUT` execution. |
| **Automatic Panic Shield (v0.12.0)** | `try...except Defect/CatchableError` | Zero-overhead, compile-time exception wrapping. Intercepts panics (`OverflowDefect`, `IndexDefect`, etc.) and converts them to PostgreSQL `ereport(ERROR)` aborts without backend server crashes (`0 SIGABRTs`). |
| **Extension Packaging** | `.control`, `--0.0.1.sql`, `install.sh` | Generates standard PostgreSQL extension control files and privileged installation scripts. |
| **Extension Enablement** | `CREATE EXTENSION <name>` | Load extensions directly using PostgreSQL's standard extension mechanism. |
| **Compile-Time Safety** | Static Effect Analysis | Enforces strict compile-time safety, preventing unhandled I/O operations and unhandled exceptions. |
| **Primitive Datatypes** | `int`, `int32`, `int64`, `float`, `string`, `cstring`, `bool` | Automatic bidirectional conversion between Nim native types and Postgres `Datum`. |
| **Enum Types** | Consuming Postgres `ENUM` in Nim | Auto-generates `CREATE TYPE ... AS ENUM` and converts Postgres OIDs to Nim enums. |
| **Composite Records** | Consuming Postgres `record` / `tuple` | Inspect and read PostgreSQL `HeapTupleHeader` attributes via Nim `tuple` and `object` types. |
| **Postgres Engine Hooks** | `emit_log`, `post_parse_analyze` | Intercept query parsing and log emission via built-in hook builders. |
| **CLI Tool (`pgxtool`)** | `init`, `create-project`, `build-extension`, `install`, `path-finders`, `test` | Scaffolding, path discovery, compilation, installation scripts, and Docker test harness. |

---

## 🛡️ Automatic Panic Shield & Safety Guarantees

Pgxcrown leverages Nim's static effect analysis and macro AST rewriting to guarantee extension safety at runtime and compile-time:

### 1. 💡 Default Parameters & `Option[T]` NULL Defense (`v0.13.0`)
Functions can define default arguments and optional parameters using Nim's `std/options`:

```nim
proc greet*(name: string = "World", count: int = 1): string =
  "Hello " & name & " x" & $count

proc test_option_param*(a: int, b: Option[int]): int =
  if b.isNone: a else: a + b.get
```

Generated SQL (`v0.13.0` DDL):
```sql
CREATE OR REPLACE FUNCTION greet(Text DEFAULT 'World', int4 DEFAULT 1) RETURNS Text AS
'myextension', 'pgx_greet'
LANGUAGE c;

CREATE OR REPLACE FUNCTION test_option_param(int4, int4 DEFAULT NULL) RETURNS int4 AS
'myextension', 'pgx_test_option_param'
LANGUAGE c;
```

> 📖 **Test Suite**: See [`tests/defaults_and_nulls/README.md`](tests/defaults_and_nulls/README.md) for full verification details and SQL test suite.

### 2. 🔌 Raw PostgreSQL Engine FFI & Unlimited Extensibility (`v0.13.1`)
Don't wait for Pgxcrown to wrap every internal PostgreSQL C function! You can directly access **hundreds of low-level PostgreSQL engine APIs** (`parser/parser.h`, `executor/executor.h`, `utils/builtins.h`, `nodes/print.h`) using Nim's native `{.importc.}` pragma.

#### 💡 Why Developers Love This:
- ⚡ **Zero Waiting**: Bind any raw C function from `postgres.h` in 2 lines of code.
- 🧹 **Macro Cleanliness**: Pgxcrown's `isImportc` macro automatically keeps low-level C declarations private while generating clean SQL `CREATE FUNCTION` DDL for your exported Nim procs (`proc my_udf*`).
- 🛡️ **Full Security & Panic Shield**: Raw C bindings wrapped inside Nim UDFs automatically inherit Pgxcrown's compile-time Panic Shield (`try...except Defect`) and `Option[T]` NULL defense.

#### 📖 Quick Example: Building a C Query Parser AST Introspector
```nim
import pgxcrown
import std/options

# 1. Bind raw C functions directly from PostgreSQL engine headers
{.push header: "parser/parser.h".}
proc raw_parser(str: cstring, mode: cint): pointer {.importc: "raw_parser".}
{.pop.}

{.push header: "nodes/print.h".}
proc nodeToString(obj: pointer): cstring {.importc: "nodeToString".}
{.pop.}

# 2. Export a high-level, safe SQL function wrapping the raw C parser
proc pg_ast_to_raw*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone: return none(string)
  
  let listPtr = raw_parser(cstring(sql_text.get), 0)
  if listPtr == nil: return none(string)
  
  return some($nodeToString(listPtr))
```

> 📖 **Case Study & Cookbook**: See [`tests/pg_ast_lens/README.md`](tests/pg_ast_lens/README.md) for a complete developer tool parsing SQL queries into PostgreSQL C parser ASTs.

### 3. 🛡️ Automatic Panic Shield (`v0.12.0`)
All functions exported via Pgxcrown's `proc myproc*(...)` are automatically wrapped inside a compile-time panic shield. Unhandled runtime defects (such as arithmetic overflow, array out-of-bounds, nil pointer access, or invalid parsing) are intercepted at runtime and safely converted into PostgreSQL `ereport(ERROR, ...)` transaction aborts.

```sql
-- Integer Overflow (2,147,483,647 + 1) -> Intercepted cleanly by Panic Shield
SELECT proof_integer_overflow(2147483647, 1);
-- Result: ERROR: Extension Defect [OverflowDefect]: over- or underflow

-- Index Out-of-Bounds -> Intercepted cleanly by Panic Shield
SELECT proof_index_out_of_bounds(5);
-- Result: ERROR: Extension Defect [IndexDefect]: index 5 not in 0 .. 2
```

> 📖 **Test Suite**: See [`tests/panic_shield/README.md`](tests/panic_shield/README.md) for full verification details and SQL test suite.

### 2. 🚫 Strict I/O & Effect Prevention
To guarantee that user-written extensions cannot compromise PostgreSQL process stability, Pgxcrown statically analyzes compiled functions. The compiler enforces that extension functions **cannot execute unchecked or unhandled I/O operations**:

- 🚫 **Unhandled File System Access**: Prevents arbitrary disk reads/writes that could corrupt database files.
- 🚫 **Unchecked Network Sockets**: Blocks unhandled TCP/UDP socket creation or HTTP requests inside engine loops.
- 🚫 **Raw Process Spawning & Signals**: Forbids invoking external OS processes or sending uncontrolled system signals.
- 🚫 **Untracked State Side-Effects**: Ensures code executes without untracked memory side-effects on PostgreSQL worker processes.
- 🚫 **Escaping Exception Boundaries**: Eliminates uncaught C/Nim FFI panics, preventing backend worker crashes (`0 SIGABRTs`).

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
