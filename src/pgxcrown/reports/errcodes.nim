## =============================================================================
## PostgreSQL Error Levels, SQLSTATE Codes & Strongly-Typed Exceptions
## =============================================================================

# -----------------------------------------------------------------------------
# Error Levels (elog.h)
# -----------------------------------------------------------------------------
const
  DEBUG5* = 10'i32
  DEBUG4* = 11'i32
  DEBUG3* = 12'i32
  DEBUG2* = 13'i32
  DEBUG1* = 14'i32
  LOG* = 15'i32
  INFO* = 17'i32
  NOTICE* = 18'i32
  WARNING* = 19'i32
  ERROR* = 21'i32
  FATAL* = 22'i32
  PANIC* = 23'i32

proc info*(): cint {.inline.} = INFO
proc notice*(): cint {.inline.} = NOTICE
proc warning*(): cint {.inline.} = WARNING
proc error*(): cint {.inline.} = ERROR

# -----------------------------------------------------------------------------
# SQLSTATE Encoding & Decoding (6-bit representation identical to MAKE_SQLSTATE)
# -----------------------------------------------------------------------------
proc makeSqlState*(s: string): cint {.noSideEffect.} =
  ## Encodes a 5-character SQLSTATE string (e.g. "22023") into PostgreSQL's 32-bit integer
  if s.len != 5: return 0
  let b1 = (ord(s[0]) - ord('0')) and 0x3F
  let b2 = (ord(s[1]) - ord('0')) and 0x3F
  let b3 = (ord(s[2]) - ord('0')) and 0x3F
  let b4 = (ord(s[3]) - ord('0')) and 0x3F
  let b5 = (ord(s[4]) - ord('0')) and 0x3F
  result = cint(b1 + (b2 shl 6) + (b3 shl 12) + (b4 shl 18) + (b5 shl 24))

proc unpackSqlState*(code: cint): string =
  ## Decodes a 32-bit PostgreSQL SQLSTATE integer back to its 5-character string representation
  var s = newString(5)
  let c = uint32(code)
  s[0] = chr(((c and 0x3F)) + ord('0'))
  s[1] = chr((((c shr 6) and 0x3F)) + ord('0'))
  s[2] = chr((((c shr 12) and 0x3F)) + ord('0'))
  s[3] = chr((((c shr 18) and 0x3F)) + ord('0'))
  s[4] = chr((((c shr 24) and 0x3F)) + ord('0'))
  result = s

# -----------------------------------------------------------------------------
# Standard PostgreSQL SQLSTATE Constants (errcodes.h)
# -----------------------------------------------------------------------------
const
  # Class 00 — Successful Completion
  ERRCODE_SUCCESSFUL_COMPLETION* = makeSqlState("00000")

  # Class 01 — Warning
  ERRCODE_WARNING* = makeSqlState("01000")
  ERRCODE_WARNING_DEPRECATED_FEATURE* = makeSqlState("01P01")

  # Class 02 — No Data
  ERRCODE_NO_DATA* = makeSqlState("02000")
  ERRCODE_NO_DATA_FOUND* = makeSqlState("P0002")

  # Class 0A — Feature Not Supported
  ERRCODE_FEATURE_NOT_SUPPORTED* = makeSqlState("0A000")

  # Class 22 — Data Exception
  ERRCODE_DATA_EXCEPTION* = makeSqlState("22000")
  ERRCODE_STRING_DATA_RIGHT_TRUNCATION* = makeSqlState("22001")
  ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE* = makeSqlState("22003")
  ERRCODE_NULL_VALUE_NOT_ALLOWED* = makeSqlState("22004")
  ERRCODE_INVALID_DATETIME_FORMAT* = makeSqlState("22007")
  ERRCODE_DATETIME_FIELD_OVERFLOW* = makeSqlState("22008")
  ERRCODE_DIVISION_BY_ZERO* = makeSqlState("22012")
  ERRCODE_INVALID_PARAMETER_VALUE* = makeSqlState("22023")
  ERRCODE_ARRAY_SUBSCRIPT_ERROR* = makeSqlState("2202E")

  # Class 23 — Integrity Constraint Violation
  ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION* = makeSqlState("23000")
  ERRCODE_RESTRICT_VIOLATION* = makeSqlState("23001")
  ERRCODE_NOT_NULL_VIOLATION* = makeSqlState("23502")
  ERRCODE_FOREIGN_KEY_VIOLATION* = makeSqlState("23503")
  ERRCODE_UNIQUE_VIOLATION* = makeSqlState("23505")
  ERRCODE_CHECK_VIOLATION* = makeSqlState("23514")

  # Class 25 — Invalid Transaction State
  ERRCODE_INVALID_TRANSACTION_STATE* = makeSqlState("25000")

  # Class 38 & 39 — External Routine Exception
  ERRCODE_EXTERNAL_ROUTINE_EXCEPTION* = makeSqlState("38000")
  ERRCODE_EXTERNAL_ROUTINE_INVOCATION_EXCEPTION* = makeSqlState("39000")

  # Class 42 — Syntax Error or Access Rule Violation
  ERRCODE_SYNTAX_ERROR* = makeSqlState("42601")
  ERRCODE_UNDEFINED_COLUMN* = makeSqlState("42703")
  ERRCODE_UNDEFINED_TABLE* = makeSqlState("42P01")
  ERRCODE_CANNOT_COERCE* = makeSqlState("42846")

  # Class 53 — Insufficient Resources
  ERRCODE_INSUFFICIENT_RESOURCES* = makeSqlState("53000")
  ERRCODE_DISK_FULL* = makeSqlState("53100")
  ERRCODE_OUT_OF_MEMORY* = makeSqlState("53200")

  # Class 55 — Object Not In Prerequisite State
  ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE* = makeSqlState("55000")
  ERRCODE_OBJECT_IN_USE* = makeSqlState("55006")
  ERRCODE_LOCK_NOT_AVAILABLE* = makeSqlState("55P03")

  # Class 58 — System Error (external errors)
  ERRCODE_IO_ERROR* = makeSqlState("58030")

  # Class P0 — PL/pgSQL & Procedural Language Exceptions
  ERRCODE_RAISE_EXCEPTION* = makeSqlState("P0001")

  # Class XX — Internal Error
  ERRCODE_INTERNAL_ERROR* = makeSqlState("XX000")

# -----------------------------------------------------------------------------
# Strongly-Typed Exceptions
# -----------------------------------------------------------------------------
type
  PgError* = object of CatchableError
    ## Exception raised by user extension code with explicit SQLSTATE, detail and hint
    sqlerrcode*: cint
    detail*: string
    hint*: string
    context*: string

  PostgresError* = object of CatchableError
    ## Exception captured from PostgreSQL C / SPI execution via PG_TRY / PG_CATCH
    sqlerrcode*: cint
    detail*: string
    hint*: string
    context*: string

# -----------------------------------------------------------------------------
# Constructors & Raisers
# -----------------------------------------------------------------------------
proc newPgError*(sqlerrcode: cint, msg: string, detail: string = "", hint: string = "", context: string = ""): ref PgError =
  ## Instantiates a new PgError with explicit SQLSTATE code
  result = newException(PgError, msg)
  result.sqlerrcode = sqlerrcode
  result.detail = detail
  result.hint = hint
  result.context = context

proc newPgError*(sqlstate: string, msg: string, detail: string = "", hint: string = "", context: string = ""): ref PgError =
  ## Instantiates a new PgError using 5-character SQLSTATE string (e.g. "22023")
  newPgError(makeSqlState(sqlstate), msg, detail, hint, context)

proc raisePgError*(sqlerrcode: cint, msg: string, detail: string = "", hint: string = "", context: string = "") {.noreturn.} =
  ## Raises a PgError with explicit SQLSTATE code
  raise newPgError(sqlerrcode, msg, detail, hint, context)

proc raisePgError*(sqlstate: string, msg: string, detail: string = "", hint: string = "", context: string = "") {.noreturn.} =
  ## Raises a PgError using 5-character SQLSTATE string (e.g. "22023")
  raise newPgError(sqlstate, msg, detail, hint, context)

