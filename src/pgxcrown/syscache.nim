{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
""".}

import datatypes/basic
from datatypes/heaptuples import HeapTuple

{.push header: "utils/syscache.h".}

var
  AMOPOPID*        {.importc.}: cint
  AMOPSTRATEGY*    {.importc.}: cint
  AUTHOID*         {.importc.}: cint
  DATABASEOID*     {.importc.}: cint
  ENUMOID*         {.importc.}: cint
  EVENTTRIGGEROID* {.importc.}: cint
  LANGOID*         {.importc.}: cint
  PROCNAMEARGSNSP* {.importc.}: cint
  PROCOID*         {.importc.}: cint
  RELOID*          {.importc.}: cint
  TYPENAMENSP*     {.importc.}: cint
  TYPEOID*         {.importc.}: cint

proc SearchSysCache*(cacheId: cint, key1, key2, key3, key4: Datum): HeapTuple {.importc.}
proc SearchSysCache1*(cacheId: cint, key1: Datum): HeapTuple {.importc.}
proc SearchSysCache2*(cacheId: cint, key1, key2: Datum): HeapTuple {.importc.}
proc SearchSysCache3*(cacheId: cint, key1, key2, key3: Datum): HeapTuple {.importc.}
proc SearchSysCache4*(cacheId: cint, key1, key2, key3, key4: Datum): HeapTuple {.importc.}
proc SysCacheGetAttr*(cacheId: cint, heap_tuple: HeapTuple, attr_number: int16, is_null: ptr bool): Datum {.importc.}
proc ReleaseSysCache*(heap_tuple: HeapTuple) {.importc.}

{.pop.}

proc HeapTupleIsValid*(tup: HeapTuple): bool {.inline.} =
  tup != nil
