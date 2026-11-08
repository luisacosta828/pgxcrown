import unittest
import std/strutils

const pgIncludeDirServer = staticExec("pg_config --includedir-server").strip()
const pgIncludeDir = staticExec("pg_config --includedir").strip()
{.passC: "-I" & (if pgIncludeDirServer.len > 0: pgIncludeDirServer else: "/usr/include/postgresql/14/server") & " -I" & (if pgIncludeDir.len > 0: pgIncludeDir else: "/usr/include/postgresql").}

{.emit: """
#include "postgres.h"
#include "utils/memutils.h"
#include "utils/palloc.h"
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

char *pg_strerror(int errnum) {
    return strerror(errnum);
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

MemoryContext CurrentMemoryContext = NULL;
MemoryContext TopMemoryContext = NULL;

void *palloc(Size size) { return malloc(size); }
void pfree(void *ptr) { if (ptr) free(ptr); }
void *repalloc(void *ptr, Size size) { return realloc(ptr, size); }

MemoryContext AllocSetContextCreateInternal(MemoryContext parent, const char *name, Size min, Size init, Size max) {
    static int dummy = 42;
    return (MemoryContext)&dummy;
}

void MemoryContextReset(MemoryContext context) {}
void MemoryContextDelete(MemoryContext context) {}
""".}

import ../src/pgxcrown
import ../src/pgxcrown/allocator
import ../src/pgxcrown/memcontext

suite "Pgxcrown - Custom Memory Allocator & MemoryContext Suite":

  test "PgxChunkHeader size and 16-byte alignment":
    check sizeof(PgxChunkHeader) == 16

  test "Postgres allocation active check outside database":
    CurrentMemoryContext = nil
    check isPostgresAllocActive() == false

  test "wrap_malloc and wrap_free lifecycle (libc fallback)":
    CurrentMemoryContext = nil
    let p = wrap_malloc(64.csize_t)
    check p != nil
    
    # Check header before free
    let header = cast[ptr PgxChunkHeader](cast[uint](p) - sizeof(PgxChunkHeader).uint)
    check header.magic == PGX_CHUNK_MAGIC
    check header.size == 64
    check header.flags == PGX_TAG_LIBC
    
    # Write and read memory
    let bytePtr = cast[ptr UncheckedArray[byte]](p)
    for i in 0 ..< 64:
      bytePtr[i] = (i mod 256).byte
    for i in 0 ..< 64:
      check bytePtr[i] == (i mod 256).byte

    wrap_free(p)

  test "wrap_calloc zeroes memory":
    CurrentMemoryContext = nil
    let p = wrap_calloc(10.csize_t, 8.csize_t)
    check p != nil
    let bytePtr = cast[ptr UncheckedArray[byte]](p)
    var allZero = true
    for i in 0 ..< 80:
      if bytePtr[i] != 0:
        allZero = false
        break
    check allZero == true
    wrap_free(p)

  test "wrap_realloc expands and preserves data":
    CurrentMemoryContext = nil
    let p = wrap_malloc(32.csize_t)
    check p != nil
    let bytePtr = cast[ptr UncheckedArray[byte]](p)
    for i in 0 ..< 32:
      bytePtr[i] = (i + 1).byte
    
    let p2 = wrap_realloc(p, 128.csize_t)
    check p2 != nil
    let bytePtr2 = cast[ptr UncheckedArray[byte]](p2)
    var preserved = true
    for i in 0 ..< 32:
      if bytePtr2[i] != (i + 1).byte:
        preserved = false
        break
    check preserved == true

    let header2 = cast[ptr PgxChunkHeader](cast[uint](p2) - sizeof(PgxChunkHeader).uint)
    check header2.magic == PGX_CHUNK_MAGIC
    check header2.size == 128
    check header2.flags == PGX_TAG_LIBC

    wrap_free(p2)

  test "wrap_malloc uses palloc when Postgres MemoryContext is active":
    var mockCtx: int = 999
    CurrentMemoryContext = cast[MemoryContext](addr mockCtx)
    check isPostgresAllocActive() == true

    let p = wrap_malloc(48.csize_t)
    check p != nil
    let header = cast[ptr PgxChunkHeader](cast[uint](p) - sizeof(PgxChunkHeader).uint)
    check header.magic == PGX_CHUNK_MAGIC
    check header.size == 48
    check header.flags == PGX_TAG_PALLOC

    wrap_free(p)
    CurrentMemoryContext = nil

  test "withMemoryContext switches and safely restores context":
    var dummy1: int = 100
    var dummy2: int = 200
    var dummyContext1 = cast[MemoryContext](addr dummy1)
    var dummyContext2 = cast[MemoryContext](addr dummy2)

    CurrentMemoryContext = dummyContext1
    check CurrentMemoryContext == dummyContext1

    withMemoryContext(dummyContext2):
      check CurrentMemoryContext == dummyContext2

    check CurrentMemoryContext == dummyContext1
    CurrentMemoryContext = nil

  test "withTopMemoryContext switches to TopMemoryContext and restores":
    var dummyTopVal: int = 500
    var dummyCurVal: int = 100
    TopMemoryContext = cast[MemoryContext](addr dummyTopVal)
    CurrentMemoryContext = cast[MemoryContext](addr dummyCurVal)

    withTopMemoryContext:
      check CurrentMemoryContext == TopMemoryContext

    check CurrentMemoryContext == cast[MemoryContext](addr dummyCurVal)
    CurrentMemoryContext = nil
    TopMemoryContext = nil

  test "withSubContext executes body within child context":
    var mockCtx: int = 123
    CurrentMemoryContext = cast[MemoryContext](addr mockCtx)
    var executed = false

    withSubContext("test_scratchpad"):
      executed = true

    check executed == true
    check CurrentMemoryContext == cast[MemoryContext](addr mockCtx)
    CurrentMemoryContext = nil
