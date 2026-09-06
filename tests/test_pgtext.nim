{.passC: "-I/usr/include/postgresql/14/server".}
import unittest
import std/[options, tables, sets, strutils]
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

suite "Pgxcrown - Zero-Cost Fast-Path PgText String Suite":

  test "PgText basic semantics, indexing, and iteration":
    var raw = "PostgreSQL + Nim = Zero-Copy"
    let pt = toPgText(raw)

    check pt.len == raw.len
    check pt.low == 0
    check pt.high == raw.len - 1
    check pt[0] == 'P'
    check pt[4] == 'g'
    check pt[13] == 'N'

    var collected = ""
    for ch in pt:
      collected.add(ch)
    check collected == raw

    var count = 0
    for i, ch in pt:
      check ch == raw[i]
      count += 1
    check count == raw.len

  test "PgText zero-copy slicing":
    var raw = "database-kernel-optimization"
    let pt = toPgText(raw)

    let s1 = pt[0 .. 7]
    check s1.len == 8
    check s1 == "database"

    let s2 = pt[9 .. 14]
    check s2.len == 6
    check s2 == "kernel"

    let s3 = pt[16 .. 27]
    check s3.len == 12
    check s3 == "optimization"

    # Out of bounds or invalid slices return empty PgText safely
    let sEmpty = pt[20 .. 5]
    check sEmpty.len == 0

  test "PgText comparisons and predicates":
    let a = toPgText("apple")
    let b = toPgText("apple")
    let c = toPgText("banana")

    check a == b
    check a != c
    check a == "apple"
    check "apple" == a
    check a != "banana"
    check a < c
    check a <= b

    let text = toPgText("PostgreSQL-17-UDF")
    check text.startsWith("Postgre")
    check text.startsWith(toPgText("Postgre"))
    check not text.startsWith("MySQL")

    check text.endsWith("UDF")
    check text.endsWith(toPgText("UDF"))
    check not text.endsWith("Postgre")

    check text.contains('1')
    check text.contains("SQL")
    check text.contains(toPgText("17"))
    check not text.contains("Redis")

    check text.find('-') == 10
    check text.find("17") == 11
    check text.find("NotFound") == -1

  test "PgText zero-copy whitespace stripping":
    let padded = toPgText("  \t\n hello world  \r\n ")
    let stripped = padded.strip()
    check stripped.len == 11
    check stripped == "hello world"

    let alreadyClean = toPgText("clean")
    check alreadyClean.strip() == "clean"

    let allSpaces = toPgText("   \t  ")
    check allSpaces.strip().len == 0

  test "PgText case conversions and concatenation":
    let mixed = toPgText("PgxCrown Fast Text")
    check mixed.toLowerAscii() == "pgxcrown fast text"
    check mixed.toUpperAscii() == "PGXCROWN FAST TEXT"

    let part1 = toPgText("Hello ")
    let part2 = toPgText("World")
    check (part1 & part2) == "Hello World"
    check (part1 & "Nim") == "Hello Nim"
    check ("Prefix: " & part2) == "Prefix: World"
    check (part2 & '!') == "World!"

  test "PgText interoperability with standard procs via implicit converter":
    proc takesNimString(s: string): string =
      "Received: " & s

    let pt = toPgText("test string")
    let res = takesNimString(pt)
    check res == "Received: test string"

    # Test with strutils join
    let words = @["One", "Two", "Three"]
    let sep = toPgText("::")
    let joined = words.join(sep)
    check joined == "One::Two::Three"

  test "PgText hashing and HashSet/Table usage":
    var textSet = initHashSet[PgText]()
    textSet.incl(toPgText("key1"))
    textSet.incl(toPgText("key2"))
    textSet.incl(toPgText("key1")) # duplicate

    check textSet.len == 2
    check toPgText("key1") in textSet
    check toPgText("key2") in textSet
    check toPgText("key3") notin textSet

  test "PgText empty and null safety":
    let empty = initPgText()
    check empty.len == 0
    check $empty == ""
    check empty == ""
    check empty.strip().len == 0
    check empty.find('a') == -1
    check not empty.startsWith("a")
    check not empty.endsWith("a")

  test "Full std/strutils standard library interoperability":
    let numPt = toPgText("4294967")
    check parseInt(numPt) == 4294967

    let floatPt = toPgText("3.14159265")
    check abs(parseFloat(floatPt) - 3.14159265) < 1e-6

    let csvPt = toPgText("postgres,nim,pgxcrown")
    check csvPt.split(',') == @["postgres", "nim", "pgxcrown"]

    let wsPt = toPgText("zero   copy\tstring\nview")
    check wsPt.splitWhitespace() == @["zero", "copy", "string", "view"]

    let repPt = toPgText("quick brown fox")
    check repPt.replace("brown", "red") == "quick red fox"

    let countPt = toPgText("mississippi")
    check countPt.count('s') == 4
    check countPt.count('p') == 2

    let rep = toPgText("abc")
    check rep.repeat(3) == "abcabcabc"
    check rep.align(6) == "   abc"
    check rep.alignLeft(6) == "abc   "

