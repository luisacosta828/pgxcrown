import std/strutils
const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") & " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}
import unittest
import std/options
import ../src/pgxcrown

{.emit: """
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#undef sprintf
#undef vsprintf
#undef snprintf
#undef vsnprintf
#undef strerror
int pg_sprintf(char *str, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsprintf(str, fmt, args);
    va_end(args);
    return ret;
}
int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsnprintf(str, count, fmt, args);
    va_end(args);
    return ret;
}
int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
    return vsnprintf(str, count, fmt, args);
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

  test "PgVector bounds-checked indexing, slicing, and mutation":
    var raw = [10'i32, 20, 30]
    var v = PgVector[int32](raw: nil, dataPtr: cast[ptr UncheckedArray[int32]](addr raw[0]), len: 3, hasNulls: false)
    expect IndexDefect:
      discard v[-1]
    expect IndexDefect:
      discard v[3]
    expect IndexDefect:
      v[5] = 99
    expect IndexDefect:
      discard v[0..5]
    expect IndexDefect:
      discard v.isNull(10)
    expect IndexDefect:
      discard v.get(-2)

  test "PgVector toPgVector ARC safety across temporary seq, mutation, and value copies":
    proc makeOwnedVec(): PgVector[int32] =
      var tmp = @[10'i32, 20, 30, 40]
      result = toPgVector(tmp)
      tmp[0] = -999
      tmp = @[1'i32]

    var src = @[10'i32, 20, 30, 40]
    var v1 = toPgVector(src)
    src[1] = 888
    src.setLen(0)
    src = @[999'i32, 998]

    var v2 = v1
    let v3 = makeOwnedVec()
    # Clobber and replace v1 so v2's copied dataPtr would dangle if ever dereferenced.
    v1[0] = -111
    v1 = toPgVector(@[1'i32])

    check v2.len == 4
    check v2[0] == 10
    check v2[1] == 20
    check v2[2] == 30
    check v2[3] == 40
    check v3 == toPgVector(@[10'i32, 20, 30, 40])

    # Mutation via activeMutDataPtr does not affect independent copies
    v2[1] = 25
    check v2[1] == 25
    check v3[1] == 20

    var iterated: seq[int32] = @[]
    for x in v2:
      iterated.add(x)
    check iterated == @[10'i32, 25, 30, 40]

    var pairSum = 0
    for i, x in v2:
      check x == v2[i]
      pairSum += i
    check pairSum == 6

    check v2.get(2) == some(30'i32)
    check @v2 == @[10'i32, 25, 30, 40]
    check toSeq(v2) == @[10'i32, 25, 30, 40]
    check $v2 == "@[10, 25, 30, 40]"
    check %v2 == %(@[10, 25, 30, 40])

    let v2Copy = v2
    var v2Diff = v2
    v2Diff[0] = 777
    check v2 == v2Copy
    check v2 != v2Diff

    proc sumOpenArray(oa: openArray[int32]): int32 =
      for x in oa:
        result += x

    check sumOpenArray(v2.toOpenArray) == 105
    check sumOpenArray(v2.toOpenArray(1, 2)) == 55

    # Owned slices must stay valid after source vector is mutated/replaced
    var sliceOwner = toPgVector(@[100'i32, 200, 300, 400])
    var sub = sliceOwner[1..2]
    sliceOwner[1] = -1
    sliceOwner = toPgVector(newSeq[int32]())

    check sub.len == 2
    check sub[0] == 200
    check sub[1] == 300
    check @sub == @[200'i32, 300]

    let subCopy = sub
    sub[0] = 222
    check sub[0] == 222
    check subCopy[0] == 200
    check sub != subCopy

    let subFromTemp = makeOwnedVec()[1..2]
    check subFromTemp.len == 2
    check @subFromTemp == @[20'i32, 30]

    let emptySlice = v3[2..1]
    check emptySlice.len == 0
    check (@emptySlice).len == 0

  test "PgVector single-evaluation guard for @ and toSeq":
    var evalCount = 0
    proc fetchVec(): PgVector[int32] =
      inc evalCount
      toPgVector(@[11'i32, 22, 33, 44])

    let seqAt = @(fetchVec())
    check evalCount == 1
    check seqAt == @[11'i32, 22, 33, 44]

    evalCount = 0
    let seqExplicit = toSeq(fetchVec())
    check evalCount == 1
    check seqExplicit == @[11'i32, 22, 33, 44]

    proc acceptSeq(s: seq[int32]): seq[int32] = s
    evalCount = 0
    let seqImplicit = acceptSeq(fetchVec())
    check evalCount == 1
    check seqImplicit == @[11'i32, 22, 33, 44]

  test "PgVector optPgVectorToOptSeq conversions":
    proc passthroughOptSeq(o: Option[seq[int32]]): Option[seq[int32]] = o

    let ownedOpt = some(toPgVector(@[5'i32, 6, 7]))
    check optPgVectorToOptSeq(ownedOpt) == some(@[5'i32, 6, 7])
    check passthroughOptSeq(ownedOpt) == some(@[5'i32, 6, 7])

    var rawBuf = [10'i32, 20, 30]
    let zeroCopyVec = PgVector[int32](
      raw: nil,
      dataPtr: cast[ptr UncheckedArray[int32]](addr rawBuf[0]),
      len: rawBuf.len,
      hasNulls: false
    )
    let zeroOpt = some(zeroCopyVec)
    check optPgVectorToOptSeq(zeroOpt) == some(@[10'i32, 20, 30])
    check passthroughOptSeq(zeroOpt) == some(@[10'i32, 20, 30])

    let noneOpt = none(PgVector[int32])
    check optPgVectorToOptSeq(noneOpt) == none(seq[int32])
    check passthroughOptSeq(noneOpt) == none(seq[int32])

  test "PgVector toSeq and optPgVectorToOptSeq in noSideEffect tags:[] context":
    proc pureSeqAccept(s: seq[int32]): seq[int32] {.noSideEffect, tags: [].} = s
    proc pureOptAccept(o: Option[seq[int32]]): Option[seq[int32]] {.noSideEffect, tags: [].} = o

    proc pureConvert(
      v: PgVector[int32],
      ov: Option[PgVector[int32]]
    ): (seq[int32], seq[int32], seq[int32], Option[seq[int32]], Option[seq[int32]]) {.noSideEffect, tags: [].} =
      let s1 = toSeq(v)
      let s2 = @v
      let s3 = pureSeqAccept(v)
      let o1 = optPgVectorToOptSeq(ov)
      let o2 = pureOptAccept(ov)
      (s1, s2, s3, o1, o2)

    let vec = toPgVector(@[4'i32, 5, 6])
    let (s1, s2, s3, o1, o2) = pureConvert(vec, some(vec))
    check s1 == @[4'i32, 5, 6]
    check s2 == @[4'i32, 5, 6]
    check s3 == @[4'i32, 5, 6]
    check o1 == some(@[4'i32, 5, 6])
    check o2 == some(@[4'i32, 5, 6])

    let (_, _, _, oNone1, oNone2) = pureConvert(vec, none(PgVector[int32]))
    check oNone1 == none(seq[int32])
    check oNone2 == none(seq[int32])
