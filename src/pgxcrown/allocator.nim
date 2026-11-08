{.push stackTrace: off, raises: [].}

import ./compiler

## =============================================================================
## Pgxcrown Low-Level Custom Memory Allocator for PostgreSQL on Linux x86_64
## Intercepts libc memory allocation routines via GNU ld linker wrapping
## (--wrap=malloc, --wrap=calloc, --wrap=realloc, --wrap=free) and routes active
## PostgreSQL allocations to PostgreSQL's native MemoryContext hierarchy.
## =============================================================================

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "utils/memutils.h"
#include "utils/palloc.h"
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#undef sprintf
#undef vsprintf
#undef snprintf
#undef vsnprintf
#undef strerror

__attribute__((weak)) MemoryContext CurrentMemoryContext = (MemoryContext)0;
__attribute__((weak)) void *palloc(Size size) { return malloc(size); }
__attribute__((weak)) void pfree(void *ptr) { if (ptr) free(ptr); }
__attribute__((weak)) void *repalloc(void *ptr, Size size) { return realloc(ptr, size); }
__attribute__((weak)) void *__real_malloc(size_t size) { return malloc(size); }
__attribute__((weak)) void *__real_calloc(size_t nmemb, size_t size) { return calloc(nmemb, size); }
__attribute__((weak)) void *__real_realloc(void *ptr, size_t size) { return realloc(ptr, size); }
__attribute__((weak)) void __real_free(void *ptr) { free(ptr); }

__attribute__((weak)) int pg_sprintf(char *str, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsprintf(str, fmt, args);
    va_end(args);
    return ret;
}

__attribute__((weak)) char *pg_strerror(int errnum) {
    return strerror(errnum);
}

__attribute__((weak)) int pg_snprintf(char *str, size_t count, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int ret = vsnprintf(str, count, fmt, args);
    va_end(args);
    return ret;
}

__attribute__((weak)) int pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args) {
    return vsnprintf(str, count, fmt, args);
}
#endif
""".}

type
  MemoryContext* {.importc: "MemoryContext", nodecl.} = pointer

  PgxChunkHeader* {.packed.} = object
    magic*: uint64
    size*: uint32
    flags*: uint32

static:
  doAssert sizeof(PgxChunkHeader) == 16, "PgxChunkHeader must be exactly 16 bytes for 16-byte alignment"

const
  PGX_CHUNK_MAGIC*: uint64 = 0x50475843524F574E'u64 # "PGXCROWN" in ASCII
  PGX_TAG_PALLOC*: uint32  = 0x00000001'u32
  PGX_TAG_LIBC*: uint32    = 0x00000002'u32
  PGX_TAG_FREED*: uint32   = 0xDEADBEEF'u32

# PostgreSQL Memory Primitives (already declared in postgres.h / palloc.h)
var CurrentMemoryContext* {.importc: "CurrentMemoryContext", nodecl.}: MemoryContext

proc palloc*(size: csize_t): pointer {.importc: "palloc", nodecl.}
proc palloc*(size: cuint): pointer {.inline.} = palloc(size.csize_t)
proc palloc*(size: int): pointer {.inline.} = palloc(size.csize_t)

proc pfree*(p: pointer) {.importc: "pfree", nodecl.}
proc repalloc*(p: pointer, size: csize_t): pointer {.importc: "repalloc", nodecl.}
proc repalloc*(p: pointer, size: cuint): pointer {.inline.} = repalloc(p, size.csize_t)
proc repalloc*(p: pointer, size: int): pointer {.inline.} = repalloc(p, size.csize_t)

# GNU ld Real Libc Primitives
proc real_malloc*(size: csize_t): pointer {.importc: "__real_malloc", cdecl.}
proc real_calloc*(nmemb: csize_t, size: csize_t): pointer {.importc: "__real_calloc", cdecl.}
proc real_realloc*(p: pointer, size: csize_t): pointer {.importc: "__real_realloc", cdecl.}
proc real_free*(p: pointer) {.importc: "__real_free", cdecl.}

# C library memset
proc memset(dest: pointer, c: cint, n: csize_t): pointer {.importc: "memset", header: "<string.h>".}

proc isPostgresAllocActive*(): bool {.inline.} =
  ## Returns true if PostgreSQL memory context subsystem is active in the current thread/process.
  CurrentMemoryContext != nil

proc wrap_malloc*(size: csize_t): pointer {.cdecl, exportc: "__wrap_malloc".} =
  if size > csize_t.high - sizeof(PgxChunkHeader).csize_t:
    return nil

  let totalSize = sizeof(PgxChunkHeader).csize_t + size
  var raw: pointer = nil
  var tag: uint32 = 0

  if isPostgresAllocActive():
    raw = palloc(totalSize)
    tag = PGX_TAG_PALLOC
  else:
    raw = real_malloc(totalSize)
    tag = PGX_TAG_LIBC

  if raw == nil:
    return nil

  let header = cast[ptr PgxChunkHeader](raw)
  header.magic = PGX_CHUNK_MAGIC
  header.size = if size > uint32.high.csize_t: uint32.high else: size.uint32
  header.flags = tag

  return cast[pointer](cast[uint](raw) + sizeof(PgxChunkHeader).uint)

proc wrap_free*(p: pointer) {.cdecl, exportc: "__wrap_free".} =
  if p == nil:
    return

  if cast[uint](p) < sizeof(PgxChunkHeader).uint:
    return

  let header = cast[ptr PgxChunkHeader](cast[uint](p) - sizeof(PgxChunkHeader).uint)
  if header.magic == PGX_CHUNK_MAGIC:
    let flags = header.flags
    header.flags = PGX_TAG_FREED
    if flags == PGX_TAG_PALLOC:
      pfree(cast[pointer](header))
    elif flags == PGX_TAG_LIBC:
      real_free(cast[pointer](header))
    elif flags == PGX_TAG_FREED:
      discard # Double-free guard: safely ignore
  else:
    real_free(p)

proc wrap_calloc*(nmemb: csize_t, size: csize_t): pointer {.cdecl, exportc: "__wrap_calloc".} =
  if nmemb != 0 and size > csize_t.high div nmemb:
    return nil

  let userSize = nmemb * size
  let p = wrap_malloc(userSize)
  if p != nil and userSize > 0:
    discard memset(p, 0, userSize)
  return p

proc wrap_realloc*(p: pointer, size: csize_t): pointer {.cdecl, exportc: "__wrap_realloc".} =
  if p == nil:
    return wrap_malloc(size)

  if size == 0:
    wrap_free(p)
    return nil

  if cast[uint](p) < sizeof(PgxChunkHeader).uint:
    return nil

  let header = cast[ptr PgxChunkHeader](cast[uint](p) - sizeof(PgxChunkHeader).uint)
  if header.magic != PGX_CHUNK_MAGIC:
    return real_realloc(p, size)

  if header.flags == PGX_TAG_FREED:
    return nil

  if size > csize_t.high - sizeof(PgxChunkHeader).csize_t:
    return nil

  let totalSize = sizeof(PgxChunkHeader).csize_t + size

  if header.flags == PGX_TAG_PALLOC:
    let newRaw = repalloc(cast[pointer](header), totalSize)
    if newRaw == nil:
      return nil
    let newHeader = cast[ptr PgxChunkHeader](newRaw)
    newHeader.size = if size > uint32.high.csize_t: uint32.high else: size.uint32
    return cast[pointer](cast[uint](newRaw) + sizeof(PgxChunkHeader).uint)
  elif header.flags == PGX_TAG_LIBC:
    let newRaw = real_realloc(cast[pointer](header), totalSize)
    if newRaw == nil:
      return nil
    let newHeader = cast[ptr PgxChunkHeader](newRaw)
    newHeader.size = if size > uint32.high.csize_t: uint32.high else: size.uint32
    return cast[pointer](cast[uint](newRaw) + sizeof(PgxChunkHeader).uint)
  else:
    return nil

{.pop.}
