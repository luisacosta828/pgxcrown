# Pgxcrown

**Build PostgreSQL Extensions in Nim**

![pgxcrown banner](banner.jpg)

## Overview

**pgxcrown** empowers developers to write PostgreSQL extensions using the Nim programming language. By combining Nim’s expressive syntax and compile-time safety with PostgreSQL’s extensibility, pgxcrown makes it easy, fast, and safe to build new database functionality.

---

## Features

### 🚀 Nim-Powered PostgreSQL Extensions
- Write PostgreSQL user-defined functions (UDFs) and extensions in Nim with ease.
- Leverage Nim’s compile-time checks and modern language features for safer and more maintainable extensions.

### 🛠️ CLI Tooling for Productivity
- `pgxtool` command-line utility for:
  - Project scaffolding (`create-project`)
  - Extension building (`build-extension`)
  - Type templates (`create-type`)
  - Hook templates, testing, and more

### 🔄 Automatic Type Mapping & Boilerplate Generation
- Maps Nim types (`int`, `float`, `string`, etc.) to PostgreSQL types.
- Generates SQL and C glue code, so you focus only on your business logic.

### 🛡️ Security & Safety by Design
- Promotes use of Nim’s `func` for extension functions, ensuring purity:
  - No side effects, heap allocation, or unsafe operations
  - Compile-time guarantees against common sources of bugs or vulnerabilities
- Declares functions as `trusted` and uses PostgreSQL’s `STRICT` mode by default.

### 🌐 Cross-Platform Support
- Works on Linux and Windows
- Handles platform-specific details like `pg_config` path discovery and deployment instructions

### 🔌 Seamless PostgreSQL Integration
- Easily register and call your Nim functions from SQL.
- SPI (Server Programming Interface) bindings let you run SQL inside your extensions.

### 🧩 Custom Types & Hooks
- Templates for custom PostgreSQL types and hooks (e.g., `emit_log`, `post_parse_analyze`).

### 🤝 Open Source & Community-Friendly
- MIT Licensed.
- Welcomes contributions, pull requests, and issues.

---

## Quick Start

### 1. Install dependencies

```bash
nimble install
```

### 2. Create a new extension project

```bash
pgxtool create-project my_extension
```

### 3. Write your extension code

Edit `src/main.nim`:

```nim
proc add_one*(a: int): int =
  a + 1
```

### 4. Build and deploy

```bash
pgxtool build-extension my_extension
# Linux:
cp *.so $(pg_config --pkglibdir)
# Windows:
# Find pg_config.exe, then copy .dll as directed.
```

### 5. Register and use in PostgreSQL

```sql
create function nim_add_one(integer) returns integer as
'libadd_one', 'pgx_add_one'
language c strict;

select nim_add_one(10); -- returns 11
```

---

## Security Features

- **Safe Function Design:** By using Nim’s `func`, pgxcrown enforces compile-time purity—no heap allocation, no side effects, and no global state—helping to avoid memory errors or security flaws.
- **Trusted and Strict:** Generated functions are marked as `trusted` and use PostgreSQL’s `STRICT` language mode, preventing unexpected NULL behavior.

---

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change. Make sure to update or add tests as appropriate.

---

## License

[MIT](https://choosealicense.com/licenses/mit/)
