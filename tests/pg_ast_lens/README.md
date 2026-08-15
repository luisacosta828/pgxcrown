# 🌳 `pg_ast_lens` — PostgreSQL Internal Query Parser AST Introspector

**Target**: PostgreSQL 14  
**Powered by**: Pgxcrown v0.13.0 (`Option[T]` NULL defense, Default Parameters, Panic Shield)

`pg_ast_lens` is a developer tool for PostgreSQL core contributors, DBAs, and extension authors. It provides direct SQL access to PostgreSQL's internal C query parser AST (`raw_parser`) and node printer (`nodeToString`) without attaching `gdb` or writing custom C debugging routines.

---

## 📜 Nim Source Code (`tests/pg_ast_lens/pg_ast_lens_test.nim`)

```nim
import pgxcrown
import std/[options, strutils, json]

# Low-level PostgreSQL internal C header imports (kept private)
{.push header: "parser/parser.h".}
type RawParseMode = cint
const RAW_PARSE_DEFAULT: RawParseMode = 0
proc raw_parser(str: cstring, mode: RawParseMode): pointer {.importc: "raw_parser".}
{.pop.}

{.push header: "nodes/print.h".}
proc nodeToString(obj: pointer): cstring {.importc: "nodeToString".}
{.pop.}

# Exported PostgreSQL SQL Functions
proc pg_ast_to_raw*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(cstring(sql_text.get), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  return some($astCStr)

proc pg_ast_to_json*(sql_text: Option[string]): Option[string] =
  if sql_text.isNone or sql_text.get.strip.len == 0:
    return none(string)

  let listPtr = raw_parser(cstring(sql_text.get), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return none(string)

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return none(string)

  let rawAst = $astCStr
  let jsonStr = "{\"status\":\"parsed\",\"raw_sql\":" & escapeJson(sql_text.get) & ",\"ast_tree\":" & escapeJson(rawAst) & "}"
  return some(jsonStr)

proc pg_ast_query_type*(sql_text: string = "SELECT 1"): string =
  if sql_text.strip.len == 0:
    return "UNKNOWN"

  let listPtr = raw_parser(cstring(sql_text), RAW_PARSE_DEFAULT)
  if listPtr == nil:
    return "SYNTAX_ERROR"

  let astCStr = nodeToString(listPtr)
  if astCStr == nil:
    return "UNKNOWN"

  let raw = ($astCStr).toUpperAscii()
  if "SELECTSTMT" in raw: return "SELECT"
  elif "INSERTSTMT" in raw: return "INSERT"
  elif "UPDATESTMT" in raw: return "UPDATE"
  elif "DELETESTMT" in raw: return "DELETE"
  elif "DROPSTMT" in raw: return "DROP"
  elif "CREATESTMT" in raw: return "CREATE"
  else: return "OTHER"
```

---

## 📜 Generated PostgreSQL SQL DDL

```sql
CREATE OR REPLACE FUNCTION pg_ast_to_raw(Text DEFAULT NULL) returns Text as
'pg_ast_lens', 'pgx_pg_ast_to_raw'
language c;

CREATE OR REPLACE FUNCTION pg_ast_to_json(Text DEFAULT NULL) returns Text as
'pg_ast_lens', 'pgx_pg_ast_to_json'
language c;

CREATE OR REPLACE FUNCTION pg_ast_query_type(Text DEFAULT 'SELECT 1') returns Text as
'pg_ast_lens', 'pgx_pg_ast_query_type'
language c;
```

---

## 🧪 Interactive `psql` Verification Queries

```sql
-- 1. Inspect raw C AST node string for a SELECT query
SELECT pg_ast_to_raw('SELECT id, name FROM users WHERE age > 21');

-- 2. Inspect query AST in JSON format
SELECT pg_ast_to_json('SELECT * FROM orders WHERE status = ''pending''');

-- 3. Detect Query AST Action Type
SELECT pg_ast_query_type(); -- Defaults to 'SELECT 1' -> returns 'SELECT'
SELECT pg_ast_query_type('INSERT INTO users (name) VALUES (''Alice'')'); -- Returns 'INSERT'
SELECT pg_ast_query_type('DROP TABLE audit_logs'); -- Returns 'DROP'

-- 4. NULL Input Defense
SELECT pg_ast_to_json(NULL); -- Returns NULL cleanly without backend crashes!
```
