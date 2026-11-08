## =============================================================================
## Pgxcrown MemoryContext & RAII Memory Management Module
## Provides idiomatic, leak-free PostgreSQL MemoryContext lifecycle management,
## RAII switching templates, and isolated scratchpad subcontext execution.
## =============================================================================

import ./compiler
import ./allocator
export allocator.MemoryContext, allocator.CurrentMemoryContext

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "utils/memutils.h"
#include <stdlib.h>

#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) MemoryContext TopMemoryContext = (MemoryContext)0;
__attribute__((weak)) MemoryContext AllocSetContextCreateInternal(MemoryContext parent, const char *name, Size min, Size init, Size max) {
    (void)parent; (void)name; (void)min; (void)init; (void)max;
    return (MemoryContext)0;
}
__attribute__((weak)) void MemoryContextReset(MemoryContext context) { (void)context; }
__attribute__((weak)) void MemoryContextDelete(MemoryContext context) { (void)context; }
#endif
""".}

var
  TopMemoryContext* {.importc: "TopMemoryContext", nodecl.}: MemoryContext

proc MemoryContextSwitchTo*(context: MemoryContext): MemoryContext {.inline.} =
  ## Directly switches CurrentMemoryContext to context, returning previous context.
  result = CurrentMemoryContext
  CurrentMemoryContext = context

proc AllocSetContextCreateInternal*(parent: MemoryContext, name: cstring,
                                    minContextSize: csize_t, initBlockSize: csize_t,
                                    maxBlockSize: csize_t): MemoryContext {.importc: "AllocSetContextCreateInternal", nodecl.}
proc MemoryContextReset*(context: MemoryContext) {.importc: "MemoryContextReset", nodecl.}
proc MemoryContextDelete*(context: MemoryContext) {.importc: "MemoryContextDelete", nodecl.}

const
  ALLOCSET_DEFAULT_MINSIZE*: csize_t = 0
  ALLOCSET_DEFAULT_INITSIZE*: csize_t = 8 * 1024
  ALLOCSET_DEFAULT_MAXSIZE*: csize_t = 8 * 1024 * 1024

proc createMemoryContext*(parent: MemoryContext, name: cstring,
                          minSize: csize_t = ALLOCSET_DEFAULT_MINSIZE,
                          initSize: csize_t = ALLOCSET_DEFAULT_INITSIZE,
                          maxSize: csize_t = ALLOCSET_DEFAULT_MAXSIZE): MemoryContext {.inline.} =
  if parent == nil:
    return nil
  AllocSetContextCreateInternal(parent, name, minSize, initSize, maxSize)

proc createMemoryContext*(parent: MemoryContext, name: string,
                          minSize: csize_t = ALLOCSET_DEFAULT_MINSIZE,
                          initSize: csize_t = ALLOCSET_DEFAULT_INITSIZE,
                          maxSize: csize_t = ALLOCSET_DEFAULT_MAXSIZE): MemoryContext {.inline.} =
  createMemoryContext(parent, cstring(name), minSize, initSize, maxSize)

proc createMemoryContext*(name: cstring,
                          minSize: csize_t = ALLOCSET_DEFAULT_MINSIZE,
                          initSize: csize_t = ALLOCSET_DEFAULT_INITSIZE,
                          maxSize: csize_t = ALLOCSET_DEFAULT_MAXSIZE): MemoryContext {.inline.} =
  createMemoryContext(CurrentMemoryContext, name, minSize, initSize, maxSize)

proc createMemoryContext*(name: string,
                          minSize: csize_t = ALLOCSET_DEFAULT_MINSIZE,
                          initSize: csize_t = ALLOCSET_DEFAULT_INITSIZE,
                          maxSize: csize_t = ALLOCSET_DEFAULT_MAXSIZE): MemoryContext {.inline.} =
  createMemoryContext(CurrentMemoryContext, cstring(name), minSize, initSize, maxSize)

proc resetMemoryContext*(ctx: MemoryContext) {.inline.} =
  if ctx != nil:
    MemoryContextReset(ctx)

proc deleteMemoryContext*(ctx: MemoryContext) {.inline.} =
  if ctx != nil:
    MemoryContextDelete(ctx)

template withMemoryContext*(targetCtx: MemoryContext, body: untyped): untyped =
  let target = targetCtx
  if target != nil:
    let prevCtx = MemoryContextSwitchTo(target)
    try:
      body
    finally:
      discard MemoryContextSwitchTo(prevCtx)
  else:
    body

template withTopMemoryContext*(body: untyped): untyped =
  withMemoryContext(TopMemoryContext, body)

template withSubContext*(subName: untyped, body: untyped): untyped =
  let subCtx = createMemoryContext(CurrentMemoryContext, subName)
  try:
    withMemoryContext(subCtx):
      body
  finally:
    deleteMemoryContext(subCtx)

template withSubContext*(parentCtx: MemoryContext, subName: untyped, body: untyped): untyped =
  let subCtx = createMemoryContext(parentCtx, subName)
  try:
    withMemoryContext(subCtx):
      body
  finally:
    deleteMemoryContext(subCtx)
