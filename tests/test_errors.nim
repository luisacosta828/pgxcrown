{.passC: "-I/usr/include/postgresql/14/server".}
import unittest
import std/strutils
import ../src/pgxcrown

{.emit: """
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#undef sprintf
#undef vsprintf
#undef strerror
int pg_sprintf(char *str, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsprintf(str, fmt, args);
    va_end(args);
    return ret;
}
char *pg_strerror(int errnum) {
    return strerror(errnum);
}
""".}

suite "Pgxcrown - Advanced Error Handling & SQLSTATE Suite":

  test "SQLSTATE 6-bit encoding and decoding round-trip":
    let codes = [
      "00000", # Successful completion
      "01000", # Warning
      "01P01", # Deprecated feature
      "02000", # No data
      "0A000", # Feature not supported
      "22000", # Data exception
      "22003", # Numeric value out of range (overflow)
      "22012", # Division by zero
      "22023", # Invalid parameter value
      "2202E", # Array subscript error
      "23505", # Unique violation
      "38000", # External routine exception
      "42601", # Syntax error
      "42P01", # Undefined table
      "53200", # Out of memory
      "58030", # IO error
      "P0001", # Raise exception
      "P0002", # No data found
      "XX000"  # Internal error
    ]

    for expected in codes:
      let encoded = makeSqlState(expected)
      if expected == "00000":
        check encoded == 0
      else:
        check encoded > 0
      let decoded = unpackSqlState(encoded)
      check decoded == expected

  test "Error level constants are defined and match PostgreSQL semantics":
    check DEBUG5 == 10
    check DEBUG1 == 14
    check LOG == 15
    check INFO == 17
    check NOTICE == 18
    check WARNING == 19
    check ERROR == 21
    check FATAL == 22
    check PANIC == 23

    check info() == INFO
    check notice() == NOTICE
    check warning() == WARNING
    check error() == ERROR

  test "Standard SQLSTATE constants are correctly pre-computed":
    check unpackSqlState(ERRCODE_SUCCESSFUL_COMPLETION) == "00000"
    check unpackSqlState(ERRCODE_WARNING) == "01000"
    check unpackSqlState(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE) == "22003"
    check unpackSqlState(ERRCODE_DIVISION_BY_ZERO) == "22012"
    check unpackSqlState(ERRCODE_INVALID_PARAMETER_VALUE) == "22023"
    check unpackSqlState(ERRCODE_ARRAY_SUBSCRIPT_ERROR) == "2202E"
    check unpackSqlState(ERRCODE_OUT_OF_MEMORY) == "53200"
    check unpackSqlState(ERRCODE_IO_ERROR) == "58030"
    check unpackSqlState(ERRCODE_RAISE_EXCEPTION) == "P0001"
    check unpackSqlState(ERRCODE_INTERNAL_ERROR) == "XX000"

  test "PgError instantiation, fields and catchability":
    try:
      raise newPgError(ERRCODE_INVALID_PARAMETER_VALUE, "Threshold must be positive", detail = "Received -10", hint = "Provide value > 0")
    except PgError as e:
      check e.msg == "Threshold must be positive"
      check e.sqlerrcode == ERRCODE_INVALID_PARAMETER_VALUE
      check unpackSqlState(e.sqlerrcode) == "22023"
      check e.detail == "Received -10"
      check e.hint == "Provide value > 0"
    except CatchableError:
      fail()

  test "raisePgError with string SQLSTATE convenience":
    try:
      raisePgError("22012", "Cannot divide by zero in custom kernel", hint = "Check denominator")
    except PgError as e:
      check e.msg == "Cannot divide by zero in custom kernel"
      check unpackSqlState(e.sqlerrcode) == "22012"
      check e.hint == "Check denominator"

  test "PostgresError instantiation and catchability":
    try:
      var pge = newException(PostgresError, "relation 'users' does not exist")
      pge.sqlerrcode = ERRCODE_UNDEFINED_TABLE
      pge.detail = "Table was dropped"
      raise pge
    except PostgresError as e:
      check e.msg == "relation 'users' does not exist"
      check unpackSqlState(e.sqlerrcode) == "42P01"
      check e.detail == "Table was dropped"
    except CatchableError:
      fail()

  test "Exception mapping logic for Defect and CatchableError types":
    var ovf = newException(OverflowDefect, "over- or underflow")
    check ovf of Defect
    check ovf of OverflowDefect

    var div0 = newException(DivByZeroDefect, "division by zero")
    check div0 of Defect
    check div0 of DivByZeroDefect

    var idx = newException(IndexDefect, "index out of bounds")
    check idx of Defect
    check idx of IndexDefect

    var valErr = newException(ValueError, "invalid integer")
    check valErr of CatchableError
    check valErr of ValueError

    var keyErr = newException(KeyError, "key not found")
    check keyErr of CatchableError
    check keyErr of KeyError
