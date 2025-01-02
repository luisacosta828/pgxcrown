from datatypes/basic import Datum, Oid
from spi import HeapTuple

{.push header: "utils/syscache.h" .}

var 
  TYPEOID*         {.importc.}: int
  AUTHOID*         {.importc.}: int
  DATABASEOID*     {.importc.}: int
  ENUMOID*         {.importc.}: int
  EVENTTRIGGEROID* {.importc.}: int
  LANGOID*         {.importc.}: int
  RELOID*          {.importc.}: int
  PROCOID*         {.importc.}: int
       

proc SearchSysCache*(cacheId: int, key1, key2, key3,key4: Datum):HeapTuple {. importc .}
proc SearchSysCache1*(cacheId: int, key1: Datum): HeapTuple {.importc.}
proc SearchSysCache2*(cacheId: int, key1, key2: Datum): HeapTuple {.importc.}
proc SearchSysCache3*(cacheId: int, key1, key2, key3: Datum): HeapTuple {.importc.}
proc SearchSysCache4*(cacheId: int, key1, key2, key4: Datum): HeapTuple {.importc.}
proc SysCacheGetAttr*(cacheId: int, heap_tuple: HeapTuple, lang_number: cuint, is_null: ptr bool):Datum {. importc .}
proc ReleaseSysCache*(heap_tuple: HeapTuple) {.importc.}

{.pop.}
