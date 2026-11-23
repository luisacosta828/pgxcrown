import std/[strutils, unittest]

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") &
         " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif
#include "utils/builtins.h"
""" .}

{.emit: """
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#undef sprintf
#undef vsprintf
#undef snprintf
#undef vsnprintf
#undef strerror
int pg_sprintf(char *str, const char *fmt, ...) {
  va_list args; va_start(args, fmt);
  int r = vsprintf(str, fmt, args);
  va_end(args); return r;
}
int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
  va_list args; va_start(args, fmt);
  int r = vsnprintf(str, count, fmt, args);
  va_end(args); return r;
}
int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
  return vsnprintf(str, count, fmt, args);
}
char *pg_strerror(int errnum) { return strerror(errnum); }

static int pgx_test_palloc_cnt = 0;
static int pgx_test_pfree_cnt = 0;
static int pgx_test_text_to_cstring_cnt = 0;

void pgx_test_reset_counters(void) {
  pgx_test_palloc_cnt = 0;
  pgx_test_pfree_cnt = 0;
  pgx_test_text_to_cstring_cnt = 0;
}
int pgx_test_get_palloc_cnt(void) { return pgx_test_palloc_cnt; }
int pgx_test_get_pfree_cnt(void) { return pgx_test_pfree_cnt; }
int pgx_test_get_text_to_cstring_cnt(void) { return pgx_test_text_to_cstring_cnt; }

void *palloc(Size size) {
  pgx_test_palloc_cnt++;
  return malloc(size ? size : 1);
}
void *palloc0(Size size) {
  pgx_test_palloc_cnt++;
  return calloc(1, size ? size : 1);
}
void pfree(void *ptr) {
  if (ptr != NULL) {
    pgx_test_pfree_cnt++;
    free(ptr);
  }
}
char *pstrdup(const char *in) {
  if (!in) return NULL;
  size_t n = strlen(in) + 1;
  char *out = (char *)palloc(n);
  memcpy(out, in, n);
  return out;
}

text *cstring_to_text(const char *s) {
  size_t len = s ? strlen(s) : 0;
  text *t = (text *)palloc(VARHDRSZ + len);
  SET_VARSIZE(t, VARHDRSZ + len);
  if (len > 0) memcpy(VARDATA(t), s, len);
  return t;
}

char *text_to_cstring(const text *t) {
  pgx_test_text_to_cstring_cnt++;
  if (t == NULL) abort();
  int len = VARSIZE_ANY_EXHDR(t);
  char *res = (char *)palloc((Size)len + 1);
  if (len > 0) memcpy(res, VARDATA_ANY(t), (size_t)len);
  res[len] = '\0';
  return res;
}
""" .}

import ../src/pgxcrown/datatypes/basic
import ../src/pgxcrown/query_builder

converter trapDatumToJsonNode(d: Datum): JsonNode =
  raise newException(AssertionDefect, "must not invoke Datum->JsonNode on Datum equality")

proc pgx_test_reset_counters() {.importc.}
proc pgx_test_get_palloc_cnt(): cint {.importc.}
proc pgx_test_get_pfree_cnt(): cint {.importc.}
proc pgx_test_get_text_to_cstring_cnt(): cint {.importc.}

suite "Pgxcrown - Distinct Datum & Concrete Basic Converters Suite":

  test "Datum distinct uint64 semantics, NullDatum, ==, $, and isZero":
    check sizeof(Datum) == sizeof(uint64)
    check NullDatum == Datum(0)
    check NullDatum.isZero()
    check Datum(0).isZero()
    check not Datum(1).isZero()
    check $Datum(0) == "0"
    check $Datum(123456789'u64) == "123456789"
    check Datum(42) == Datum(42)
    check Datum(42) != Datum(43)

  test "Concrete integer & Oid converter roundtrips":
    # Oid
    let oidIn = 23.Oid
    let oidDatum: Datum = oidIn
    let oidOut: Oid = oidDatum
    check oidOut == 23.Oid

    # uint32 via explicit helper procs (avoids Oid alias collision)
    let u32Datum = UInt32ToDatum(0xDEADBEEF'u32)
    check DatumToUInt32(u32Datum) == 0xDEADBEEF'u32

    # int64
    for v in [low(int64), -9_000_000_000_000'i64, -1'i64, 0'i64, 42'i64, high(int64)]:
      let d: Datum = v
      let outV: int64 = d
      check outV == v

    # int32
    for v in [low(int32), -42'i32, 0'i32, 123456'i32, high(int32)]:
      let d: Datum = v
      let outV: int32 = d
      check outV == v

    # int (including 64-bit values like 5_000_000_000 and negative values)
    for v in [low(int), -5_000_000_000, -42, 0, 42, 5_000_000_000, high(int)]:
      let d: Datum = v
      let outV: int = d
      check outV == v

    # Cross-check: Int32GetDatum(-42'i32) read back as Nim int (sign-extended in C)
    let d32Neg = Int32GetDatum(-42'i32)
    let iFrom32: int = d32Neg
    check iFrom32 == -42
    let i32From32: int32 = d32Neg
    check i32From32 == -42'i32

    # int16
    for v in [low(int16), -1234'i16, 0'i16, high(int16)]:
      let d: Datum = v
      let outV: int16 = d
      check outV == v

    # int8
    for v in [low(int8), -42'i8, -1'i8, 0'i8, 127'i8]:
      let d: Datum = v
      let outV: int8 = d
      check outV == v
      check DatumGetInt8(d) == v

    # uint64
    for v in [0'u64, 1'u64, 0xCAFEBABEDEADBEEF'u64, high(uint64)]:
      let d: Datum = v
      let outV: uint64 = d
      check outV == v

    # uint
    for v in [0'u, 42'u, 5_000_000_000'u, high(uint)]:
      let d: Datum = v
      let outV: uint = d
      check outV == v

    # uint16
    for v in [0'u16, 1234'u16, high(uint16)]:
      let d: Datum = v
      let outV: uint16 = d
      check outV == v

    # uint8
    for v in [0'u8, 128'u8, high(uint8)]:
      let d: Datum = v
      let outV: uint8 = d
      check outV == v

  test "Concrete char, bool, float32, float64/float, cstring/Pointer, Name roundtrips":
    # char / cchar
    for v in [cchar('\0'), cchar('A'), cchar('z'), cchar('\x7f')]:
      let d: Datum = v
      let outV: cchar = d
      check outV == v
      let outChar: char = d
      check outChar == char(v)

    # bool
    let dTrue: Datum = true
    let dFalse: Datum = false
    let bTrue: bool = dTrue
    let bFalse: bool = dFalse
    check bTrue == true
    check bFalse == false
    check DatumGetBool(dTrue) == true
    check DatumGetBool(dFalse) == false

    # float32 / cfloat
    for v in [0.0'f32, -12.25'f32, 3.5'f32, 1.234567'f32]:
      let d: Datum = v
      let outF32: float32 = d
      let outCFlt: cfloat = d
      check cast[uint32](outF32) == cast[uint32](v)
      check cast[uint32](outCFlt) == cast[uint32](v)
      check cast[uint32](DatumGetFloat4(d)) == cast[uint32](v)

    # float64 / float / cdouble bit-exact precision (must NOT truncate to float32!)
    let pi = 3.141592653589793
    let dPi: Datum = pi
    let outF64: float64 = dPi
    let outFloat: float = dPi
    let outCDbl: cdouble = dPi
    check cast[uint64](outF64) == cast[uint64](pi)
    check cast[uint64](outFloat) == cast[uint64](pi)
    check cast[uint64](outCDbl) == cast[uint64](pi)
    check outFloat == 3.141592653589793

    # cstring & Pointer
    let csIn = cstring("pgxcrown-cstring")
    let csDatum: Datum = csIn
    let csOut: cstring = csDatum
    check $csOut == "pgxcrown-cstring"
    let ptrOut: Pointer = DatumToPointer(csDatum)
    check $ptrOut == "pgxcrown-cstring"
    let ptrDatum = PointerToDatum(ptrOut)
    check ptrDatum == csDatum

    # CstringToNimString (including nil safety)
    let nilCs: cstring = nil
    let sFromNil: string = nilCs
    let sFromCs: string = csIn
    check sFromNil == ""
    check sFromCs == "pgxcrown-cstring"

    # Name
    var nd: NameData
    let label = "custom_pg_name"
    for i, ch in label:
      nd.data[i] = ch
    nd.data[label.len] = '\0'
    let nameIn: Name = addr nd
    let nameDatum: Datum = nameIn
    let nameOut: Name = nameDatum
    check nameOut == nameIn
    check $NameStr(nameOut[]) == "custom_pg_name"

  test "DatumToNimString zero-leak and Datum(0) null safety":
    pgx_test_reset_counters()

    # Null Datum(0) must return "" and NEVER call text_to_cstring
    let emptyFromNull: string = Datum(0)
    check emptyFromNull == ""
    check pgx_test_get_text_to_cstring_cnt() == 0
    check pgx_test_get_palloc_cnt() == 0
    check pgx_test_get_pfree_cnt() == 0

    # Non-null string roundtrip via StringToDatum -> DatumToNimString
    let orig = "PostgreSQL distinct Datum zero-leak test!"
    let d: Datum = orig
    check pgx_test_get_palloc_cnt() == 1 # cstring_to_text allocation

    let pallocBefore = pgx_test_get_palloc_cnt()
    let pfreeBefore = pgx_test_get_pfree_cnt()
    for _ in 0 ..< 100:
      let s: string = d
      check s == orig
    check pgx_test_get_text_to_cstring_cnt() == 100
    let pallocDelta = pgx_test_get_palloc_cnt() - pallocBefore
    let pfreeDelta = pgx_test_get_pfree_cnt() - pfreeBefore
    check pallocDelta == 100
    check pfreeDelta == 100

    # Empty string roundtrip
    let dEmpty: Datum = ""
    let sEmpty: string = dEmpty
    check sEmpty == ""

    # Free the two test text* Datums
    pfree(DatumToPointer(d))
    pfree(DatumToPointer(dEmpty))
    check pgx_test_get_palloc_cnt() == pgx_test_get_pfree_cnt()

  test "Distinct Datum blocks unsafe uint64 / raw-pointer / arithmetic implicit conversions":
    check not compiles((block:
      let x: uint64 = 123'u64
      let s: string = x
      discard s
    ))
    check not compiles((block:
      let x: uint64 = 123'u64
      let c: cstring = x
      discard c
    ))
    check not compiles((block:
      let s: string = "abc"
      let x: uint64 = s
      discard x
    ))
    check not compiles((block:
      let b = true
      let x: uint64 = b
      discard x
    ))
    # Note: with `import basic`, `d == 0` resolves via `IntToDatum(0)`; raw pointer/arithmetic ops on Datum remain blocked.
    check not compiles((block:
      let d = Datum(0)
      discard(d == pointer(nil))
    ))
    check not compiles((block:
      let d = Datum(0)
      let p: pointer = d
      discard p
    ))
    check not compiles((block:
      let p: pointer = nil
      let d: Datum = p
      discard d
    ))
    check not compiles((block:
      let d = Datum(0)
      discard(d + Datum(1))
    ))
    check not compiles((block:
      let d = Datum(0)
      discard(d - Datum(1))
    ))
    check not compiles((block:
      let d = Datum(0)
      discard(d and Datum(1))
    ))
    check not compiles((block:
      let d = Datum(0)
      discard(d shl 1)
    ))

  test "Datum == and != never fall back to competing Datum->JsonNode converters":
    check Datum(42) != Datum(0)
    check Datum(0) == NullDatum
    check Datum(42) == Datum(42)
    check isZero(Datum(0))
    check not isZero(Datum(42))

  test "Raw Datum blocked across QueryBuilder while user distinct uint64 still works":
    type
      ExternalId = distinct uint64
      DistinctDatum = distinct Datum
      BadDatumRow = object
        id: int64
        d: Datum
      BadDatumSeqRow = object
        id: int64
        ds: seq[Datum]
      BadDistinctDatumRow = object
        id: int64
        dd: DistinctDatum

    let itemsTbl = table("items", "i")
    check not compiles(toParam(Datum(42)))
    check not compiles(toQueryParam(Datum(42)))
    check not compiles((block:
      var p: QueryParam = Datum(42)
      p
    ))
    check not compiles(formatSqlValue(Datum(42)))
    check not compiles(formatSqlValue(@[Datum(42)]))
    check not compiles(formatSqlValue(newSeq[Datum]()))
    check not compiles(formatSqlValue(some(Datum(42))))
    check not compiles(formatSqlValue(none(Datum)))
    check not compiles(formatSqlValue(@[some(Datum(42))]))
    check not compiles(toParam(@[Datum(42)]))
    check not compiles(toParam(some(Datum(42))))
    # Note: Row/Values accept varargs[QueryParam, toQueryParam] (covered by toQueryParam above;
    # Nim 2.4.0's `compiles(...)` does not propagate varargs coercion errors even though `nim c` rejects them).
    check not compiles(Update(itemsTbl).Set(itemsTbl.x, Datum(42)))
    check not compiles(itemsTbl.x == Datum(42))
    check not compiles(itemsTbl.x != Datum(42))
    check not compiles(itemsTbl.data["x"] == Datum(42))
    check not compiles(itemsTbl.data["x"] != Datum(42))
    check not compiles(Select(Datum(42) as "x"))
    check not compiles(Datum(42) as "x")
    check not compiles(toOrderExpr(Datum(42)))
    check not compiles(createTableFrom(BadDatumRow))
    check not compiles(createTableFrom(BadDatumSeqRow))
    check not compiles(toParam(DistinctDatum(Datum(1))))
    check not compiles(toQueryParam(DistinctDatum(Datum(1))))
    check not compiles(formatSqlValue(DistinctDatum(Datum(1))))
    check not compiles(itemsTbl.x == DistinctDatum(Datum(1)))
    check not compiles(Select(DistinctDatum(Datum(1)) as "x"))
    check not compiles(createTableFrom(BadDistinctDatumRow))

    # Positive control: user-defined distinct uint64 still works cleanly
    let ext = ExternalId(77'u64)
    check $toParam(ext) == "77"
    let qExt: QueryParam = ext
    check $qExt == "77"
    check formatSqlValue(ext) == "77"
    check formatSqlValue(newSeq[ExternalId]()) == "ARRAY[]::bigint[]"
    let qSel = Select(itemsTbl.id).From(itemsTbl).Where(itemsTbl.id == ext and itemsTbl.data["id"] == ext)
    check "WHERE \"i\".\"id\" = 77" in $qSel
    check "\"i\".\"data\" -> 'id' = 77" in $qSel
