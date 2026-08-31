import std/[unittest, strutils]
import ../src/pgxcrown/pgxtool

suite "Pgxcrown - Comprehensive Base Types Generation & Parsing Suite":

  test "All available_base_types are covered and valid":
    check available_base_types.len == 15
    check "int" in available_base_types
    check "int16" in available_base_types
    check "int32" in available_base_types
    check "int64" in available_base_types
    check "uint" in available_base_types
    check "uint16" in available_base_types
    check "uint32" in available_base_types
    check "uint64" in available_base_types
    check "float" in available_base_types
    check "float32" in available_base_types
    check "float64" in available_base_types
    check "char" in available_base_types
    check "string" in available_base_types
    check "cstring" in available_base_types
    check "bool" in available_base_types

  test "Integer Base Types Generation (int, int16, int32, int64)":
    let (intSrc, intSql) = generateTypeSource("my_int", "int")
    check "type\n  my_int* {.pgxType: int.} = distinct int" in intSrc
    check "parseInt($s).int.my_int" in intSrc
    check "$val.int" in intSrc
    check "SELECT '42'::my_int;" in intSql

    let (int16Src, int16Sql) = generateTypeSource("small_val", "int16")
    check "type\n  small_val* {.pgxType: int16.} = distinct int16" in int16Src
    check "parseInt($s).int16.small_val" in int16Src
    check "SELECT '42'::small_val;" in int16Sql

    let (int64Src, int64Sql) = generateTypeSource("big_val", "int64")
    check "type\n  big_val* {.pgxType: int64.} = distinct int64" in int64Src
    check "parseBiggestInt($s).big_val" in int64Src
    check "SELECT '42'::big_val;" in int64Sql

  test "Unsigned Integer Base Types Generation (uint, uint16, uint32, uint64)":
    let (uSrc, uSql) = generateTypeSource("u_val", "uint")
    check "type\n  u_val* {.pgxType: uint.} = distinct uint" in uSrc
    check "parseUInt($s).uint.u_val" in uSrc
    check "SELECT '42'::u_val;" in uSql

    let (u64Src, u64Sql) = generateTypeSource("u64_val", "uint64")
    check "type\n  u64_val* {.pgxType: uint64.} = distinct uint64" in u64Src
    check "parseBiggestUInt($s).u64_val" in u64Src
    check "SELECT '42'::u64_val;" in u64Sql

  test "Floating Point Base Types Generation (float, float32, float64)":
    let (fSrc, fSql) = generateTypeSource("geo_coord", "float64")
    check "type\n  geo_coord* {.pgxType: float64.} = distinct float64" in fSrc
    check "parseFloat($s).float64.geo_coord" in fSrc
    check "$val.float64" in fSrc
    check "SELECT '3.14'::geo_coord;" in fSql

    let (f32Src, f32Sql) = generateTypeSource("temp_f32", "float32")
    check "type\n  temp_f32* {.pgxType: float32.} = distinct float32" in f32Src
    check "parseFloat($s).float32.temp_f32" in f32Src
    check "SELECT '3.14'::temp_f32;" in f32Sql

  test "Text and String Base Types Generation (string, cstring, char)":
    let (strSrc, strSql) = generateTypeSource("username", "string")
    check "type\n  username* {.pgxType: string.} = distinct string" in strSrc
    check "($s).username" in strSrc
    check "$val.string" in strSrc
    check "SELECT 'hello'::username;" in strSql

    let (charSrc, charSql) = generateTypeSource("initial", "char")
    check "type\n  initial* {.pgxType: char.} = distinct char" in charSrc
    check "($s)[0].initial" in charSrc
    check "$val.char" in charSrc
    check "SELECT 'A'::initial;" in charSql

  test "Boolean Base Type Generation (bool)":
    let (boolSrc, boolSql) = generateTypeSource("is_active", "bool")
    check "type\n  is_active* {.pgxType: bool.} = distinct bool" in boolSrc
    check "parseBool($s).is_active" in boolSrc
    check "$val.bool" in boolSrc
    check "SELECT 'true'::is_active;" in boolSql
