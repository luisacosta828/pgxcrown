{.passC: "-I/usr/include/postgresql/14/server".}
import unittest
import std/options
import std/math
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

suite "Pgxcrown - Zero-Cost Fast-Path PgVector[T] Suite":

  test "PgVector[float64] basic semantics, indexing, and iteration":
    var rawData = [1.5, 2.5, 3.5, 4.5, 5.5]
    let vec = PgVector[float64](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[float64]](addr rawData[0]),
      len: rawData.len,
      hasNulls: false
    )

    check vec.len == 5
    check vec.low == 0
    check vec.high == 4
    check vec[0] == 1.5
    check vec[2] == 3.5
    check vec[4] == 5.5

    var sumVal = 0.0
    for x in vec:
      sumVal += x
    check sumVal == 17.5

    var count = 0
    for i, x in vec:
      check x == rawData[i]
      count += 1
    check count == 5

  test "PgVector zero-copy slicing":
    var rawData = [10.0, 20.0, 30.0, 40.0, 50.0]
    let vec = PgVector[float64](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[float64]](addr rawData[0]),
      len: rawData.len,
      hasNulls: false
    )

    let sub = vec[1 .. 3]
    check sub.len == 3
    check sub[0] == 20.0
    check sub[1] == 30.0
    check sub[2] == 40.0

    # Verify mutating underlying buffer affects slice directly (zero-copy proof)
    rawData[2] = 99.0
    check sub[1] == 99.0

  test "PgVector openArray interop and standard library compatibility":
    var rawData = [1.0, 2.0, 3.0, 4.0]
    let vec = PgVector[float64](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[float64]](addr rawData[0]),
      len: rawData.len,
      hasNulls: false
    )

    proc calcMean(oa: openArray[float64]): float64 =
      var total = 0.0
      for v in oa: total += v
      total / float64(oa.len)

    check calcMean(vec.toOpenArray) == 2.5
    check calcMean(vec.toOpenArray(1, 2)) == 2.5

  test "PgVector sequence conversions (@ and toSeq converter)":
    var rawData: array[3, int32] = [100'i32, 200, 300]
    let vec = PgVector[int32](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[int32]](addr rawData[0]),
      len: rawData.len,
      hasNulls: false
    )

    # Explicit @ conversion
    let s: seq[int32] = @vec
    check s == @[100'i32, 200, 300]

    # Implicit toSeq converter
    proc takesSeq(sq: seq[int32]): int32 =
      for x in sq: result += x

    check takesSeq(vec) == 600

    # toPgVector constructor from seq
    let newVec = toPgVector(@[7'i32, 8, 9])
    check newVec.len == 3
    check newVec[0] == 7
    check newVec[2] == 9

  test "PgVector Null handling and Option[T] retrieval":
    let nullMap = @[false, true, false]
    let nullVals = @[1.0, 0.0, 3.0]
    let vecWithNull = PgVector[float64](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[float64]](unsafeAddr nullVals[0]),
      len: 3,
      hasNulls: true,
      nullElems: nullVals,
      nullBitmap: nullMap
    )

    check not vecWithNull.isNull(0)
    check vecWithNull.isNull(1)
    check not vecWithNull.isNull(2)

    check vecWithNull.get(0) == some(1.0)
    check vecWithNull.get(1) == none(float64)
    check vecWithNull.get(2) == some(3.0)

  test "PgVector empty vector semantics":
    let emptyVec = PgVector[float64](raw: nil, dataPtr: nil, len: 0, hasNulls: false)
    check emptyVec.len == 0
    check (@emptyVec).len == 0
    var sumVal = 0.0
    for x in emptyVec: sumVal += x
    check sumVal == 0.0

  test "PgVector equality and dollar string representation":
    var raw1 = [1'i64, 2, 3]
    var raw2 = [1'i64, 2, 3]
    var raw3 = [1'i64, 2, 4]
    let v1 = PgVector[int64](raw: nil, dataPtr: cast[ptr UncheckedArray[int64]](addr raw1[0]), len: 3, hasNulls: false)
    let v2 = PgVector[int64](raw: nil, dataPtr: cast[ptr UncheckedArray[int64]](addr raw2[0]), len: 3, hasNulls: false)
    let v3 = PgVector[int64](raw: nil, dataPtr: cast[ptr UncheckedArray[int64]](addr raw3[0]), len: 3, hasNulls: false)

    check v1 == v2
    check v1 != v3
    check $v1 == "@[1, 2, 3]"

  test "All numeric types support (int16, int32, int64, float32, float64, bool)":
    var b = [true, false, true]
    let vb = PgVector[bool](raw: nil, dataPtr: cast[ptr UncheckedArray[bool]](addr b[0]), len: 3, hasNulls: false)
    check vb.len == 3
    check vb[0] == true
    check vb[1] == false

    var i16 = [10'i16, 20, 30]
    let vi16 = PgVector[int16](raw: nil, dataPtr: cast[ptr UncheckedArray[int16]](addr i16[0]), len: 3, hasNulls: false)
    check vi16.len == 3
    check vi16[1] == 20

    var f32 = [1.25'f32, 2.5, 5.0]
    let vf32 = PgVector[float32](raw: nil, dataPtr: cast[ptr UncheckedArray[float32]](addr f32[0]), len: 3, hasNulls: false)
    check vf32.len == 3
    check vf32[2] == 5.0
