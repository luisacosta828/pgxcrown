## =============================================================================
## PostgreSQL Server Programming Interface (SPI) Bridge & High-Level Row Consumer.
## Provides strongly-typed object mapping (.fetch[T]), optional single-row queries
## (.fetchOne[T]), scalar aggregations (.fetchScalar[T]), and collection reducers.
## =============================================================================

import std/[tables, options, strutils, json]
export json, tables
from datatypes/basic import PDatum, POid, NameData, Oid, oidvector
from datatypes/heaptuples import HeapTuple, TupleDesc
import query_builder

{.emit: """/*INCLUDESECTION*/
#include "postgres.h"
#include "executor/spi.h"

static inline TupleDesc pgx_spi_get_tupdesc(SPITupleTable* tuptable) {
  if (tuptable == NULL) return NULL;
  return tuptable->tupdesc;
}

static inline int pgx_spi_get_natts(TupleDesc tupdesc) {
  if (tupdesc == NULL) return 0;
  return tupdesc->natts;
}

static inline HeapTuple pgx_spi_get_tuple(SPITupleTable* tuptable, uint64 idx) {
  if (tuptable == NULL || tuptable->vals == NULL) return NULL;
  return tuptable->vals[idx];
}
""".}

type
  DbReadEffect* = object of RootEffect
  DbWriteEffect* = object of DbReadEffect

  const_string* {.importc: "const char*".} = cstring

  Column* = Table[string, string]
  Row* = seq[Column]
  ResultSet* = seq[Row]

  TupleTable* {.importc: "SPITupleTable*".} = pointer

  OK* {.pure.} = enum
    CONNECT = 1,
    FINISH, FETCH, UTILITY,
    SELECT, SELINTO, INSERT,
    DELETE, UPDATE, CURSOR
    INSERT_RETURNING, DELETE_RETURNING, UPDATE_RETURNING,
    REWRITTEN, REL_REGISTER, REL_UNREGISTER, TD_REGISTER

  ERROR* {.pure.} = enum
    CONNECT = 1,
    COPY, OPUNKNOWN, UNCONNECTED,
    ARGUMENT = 6,
    PARAM, TRANSACTION, NOATTRIBUTE, NOOUTFUNC,
    TYPEUNKNOWN, REL_DUPLICATE, REL_NOT_FOUND

{.push header: "executor/spi.h".}
proc connect*(): cint {.importc: "SPI_connect".}
proc finish*(): cint {.importc: "SPI_finish".}
proc exec*(c: const_string, count: clong): cint {.importc: "SPI_exec".}
proc execute*(c: const_string, read_only: cchar, count: clong): cint {.importc: "SPI_execute".}
proc execute_with_args*(c: const_string, nargs: cint, argtypes: POid, values: PDatum, Nulls: const_string,
                        read_only: cchar, count: clong): cint {.importc: "SPI_execute_with_args".}
proc fname*(tupdesc: TupleDesc, fnumber: cint): const_string {.importc: "SPI_fname".}
proc gettype*(tupdesc: TupleDesc, fnumber: cint): const_string {.importc: "SPI_gettype".}
proc getvalue*(tupl: HeapTuple, tupdesc: TupleDesc, fnumber: cint): const_string {.importc: "SPI_getvalue".}
{.pop.}

proc getTupdesc*(tuptable: TupleTable): TupleDesc {.importc: "pgx_spi_get_tupdesc".}
proc getNatts*(tupdesc: TupleDesc): cint {.importc: "pgx_spi_get_natts".}
proc getTuple*(tuptable: TupleTable, idx: uint64): HeapTuple {.importc: "pgx_spi_get_tuple".}

# =============================================================================
# Type Converters & Row Mapper
# =============================================================================

proc parseValue*[T](val: string): T {.tags: [].} =
  ## Safely parses a string column into a strongly typed Nim value
  when T is int:
    try: parseInt(val) except CatchableError: 0
  elif T is int32:
    try: int32(parseInt(val)) except CatchableError: 0'i32
  elif T is int16:
    try: int16(parseInt(val)) except CatchableError: 0'i16
  elif T is int8:
    try: int8(parseInt(val)) except CatchableError: 0'i8
  elif T is uint32:
    try: uint32(parseUInt(val)) except CatchableError: 0'u32
  elif T is int64:
    try: int64(parseBiggestInt(val)) except CatchableError: 0'i64
  elif T is float:
    try: parseFloat(val) except CatchableError: 0.0
  elif T is float64:
    try: parseFloat(val) except CatchableError: 0.0
  elif T is float32:
    try: float32(parseFloat(val)) except CatchableError: 0.0'f32
  elif T is bool:
    val == "t" or val == "true" or val == "1" or val == "TRUE"
  elif T is string:
    val
  elif T is cstring:
    cstring(val)
  elif T is char:
    if val.len > 0: val[0] else: '\0'
  elif T is JsonNode:
    {.cast(tags: []).}:
      if val.len == 0: newJNull()
      else: (try: parseJson(val) except CatchableError: newJNull())
  elif T is enum:
    try: parseEnum[T](val) except CatchableError: default(T)
  elif T is Option:
    if val.len == 0:
      none(typeof(default(T).get))
    else:
      some(parseValue[typeof(default(T).get)](val))
  else:
    default(T)

proc mapRowTo*[T: object](row: Table[string, string]): T {.tags: [].} =
  ## Maps a SPI row Table into a strongly typed Nim object via field reflection
  for name, value in fieldPairs(result):
    if row.hasKey(name):
      value = parseValue[typeof(value)](row[name])

# =============================================================================
# SPI Initialization & Query Templates
# =============================================================================

var SPI_processed* {.importc: "SPI_processed".}: uint64
var SPI_tuptable* {.importc: "SPI_tuptable".}: TupleTable

template spi_init*(statements: untyped) =
  var connection_status {.used.} = connect()
  statements
  var finish_status {.used.} = finish()

template query*(c: const_string, obj: untyped) =
  discard exec(const_string(c), 0)
  var obj {.inject.}: ResultSet = @[]
  if SPI_tuptable != nil:
    let tupdesc = getTupdesc(SPI_tuptable)
    if tupdesc != nil:
      let natts = int(getNatts(tupdesc))
      if SPI_processed > 0 and natts > 0:
        for rowIdx in 0 ..< int(SPI_processed):
          let tup = getTuple(SPI_tuptable, uint64(rowIdx))
          if tup != nil:
            var row: Row = @[]
            for colIdx in 1 .. natts:
              let colname = fname(tupdesc, cint(colIdx))
              let val = getvalue(tup, tupdesc, cint(colIdx))
              let k = if colname != nil: $colname else: "col_" & $colIdx
              let v = if val != nil: $val else: ""
              row.add([(k, v)].toTable)
            if row.len > 0:
              obj.add(row)

# =============================================================================
# High-Level SPI Consumer Procs (Eager Fetch, Optionals, Reducers)
# =============================================================================

proc fetchRawRows*(sqlQuery: string): seq[Table[string, string]] {.tags: [DbReadEffect].} =
  ## Internal: Executes raw SQL via SPI and returns a flat seq of row tables
  result = @[]
  spi_init:
    let rc = exec(const_string(sqlQuery), 0)
    if rc >= 0 and SPI_tuptable != nil:
      let tupdesc = getTupdesc(SPI_tuptable)
      if tupdesc != nil:
        let natts = int(getNatts(tupdesc))
        if SPI_processed > 0 and natts > 0:
          for rowIdx in 0 ..< int(SPI_processed):
            let tup = getTuple(SPI_tuptable, uint64(rowIdx))
            if tup != nil:
              var rowTable = initTable[string, string]()
              for colIdx in 1 .. natts:
                let colname = fname(tupdesc, cint(colIdx))
                let val = getvalue(tup, tupdesc, cint(colIdx))
                let k = if colname != nil: $colname else: "col_" & $colIdx
                let v = if val != nil: $val else: ""
                rowTable[k] = v
              result.add(rowTable)

proc fetchRows*(query: ExecutableQuery): seq[Table[string, string]] {.tags: [DbReadEffect].} =
  ## Executes a fluent query via SPI and returns rows as key-value string tables
  fetchRawRows($query)

proc fetch*[T: object](query: ExecutableQuery): seq[T] {.tags: [DbReadEffect].} =
  ## Maps fluent query result rows directly into a sequence of typed Nim objects
  let rawRows = fetchRawRows($query)
  result = @[]
  for r in rawRows:
    result.add(mapRowTo[T](r))

proc fetch*[T: object](query: ExecutableQuery, _: typedesc[T]): seq[T] {.tags: [DbReadEffect].} =
  fetch[T](query)

proc fetchOne*[T: object](query: ExecutableQuery): Option[T] {.tags: [DbReadEffect].} =
  ## Fetches the first row of a fluent query as an Option[T], or none(T) if empty
  let items = fetch[T](query)
  if items.len > 0:
    return some(items[0])
  return none(T)

proc fetchOne*[T: object](query: ExecutableQuery, _: typedesc[T]): Option[T] {.tags: [DbReadEffect].} =
  fetchOne[T](query)

proc fetchScalar*[T](query: ExecutableQuery): T {.tags: [DbReadEffect].} =
  ## Fetches a single scalar value from the first column of the first row (e.g. COUNT(*), SUM(x))
  let rawRows = fetchRawRows($query)
  if rawRows.len > 0:
    for _, val in rawRows[0]:
      return parseValue[T](val)
  return parseValue[T]("")

proc fetchCount*(query: ExecutableQuery): int {.tags: [DbReadEffect].} =
  ## Executes fluent query and returns total processed count
  let rawRows = fetchRawRows($query)
  return rawRows.len

# =============================================================================
# Stream Helpers & Reducers
# =============================================================================

proc firstOption*[T](items: openArray[T]): Option[T] =
  ## Returns the first item as an Option or none
  if items.len > 0: some(items[0]) else: none(T)

proc toTable*[T, K, V](items: openArray[T], keySelector: proc(x: T): K {.closure.}, valSelector: proc(x: T): V {.closure.}): Table[K, V] {.effectsOf: keySelector, effectsOf: valSelector.} =
  ## Transforms a collection of items into a key-value Table
  result = initTable[K, V]()
  for item in items:
    result[keySelector(item)] = valSelector(item)

proc any*[T](items: openArray[T], predicate: proc(x: T): bool {.closure.}): bool {.effectsOf: predicate.} =
  ## Returns true if any item matches the predicate
  for item in items:
    if predicate(item): return true
  return false

proc all*[T](items: openArray[T], predicate: proc(x: T): bool {.closure.}): bool {.effectsOf: predicate.} =
  ## Returns true if all items match the predicate
  for item in items:
    if not predicate(item): return false
  return true

# =============================================================================
# Direct Object Schema & Entity Operations via SPI
# =============================================================================

proc spiCreateTableFrom*[T: object](tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [DbWriteEffect].} =
  ## Inspects properties of object type T, generates CREATE TABLE DDL, and executes it via SPI
  let ddl = createTableFromType[T](tableName, ifNotExists, primaryKey)
  var ret = 0
  spi_init:
    ret = int(exec(const_string(ddl), 0))
  return ret

proc spiCreateTableFrom*[T: object](obj: T, tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [DbWriteEffect].} =
  ## Inspects properties of an object instance, generates CREATE TABLE DDL, and executes it via SPI
  spiCreateTableFrom[T](tableName, ifNotExists, primaryKey)

proc spiCreateTableFrom*[T: object](t: typedesc[T], tableName: string = "", ifNotExists: bool = true, primaryKey: string = "id"): int {.tags: [DbWriteEffect].} =
  ## Inspects properties of a typedesc[T], generates CREATE TABLE DDL, and executes it via SPI
  spiCreateTableFrom[T](tableName, ifNotExists, primaryKey)

proc spiInsertFrom*[T: object](obj: T, tableName: string = ""): int {.tags: [DbWriteEffect].} =
  ## Inspects object instance, generates INSERT statement, and executes it via SPI
  let q = insertFrom(obj, tableName)
  var ret = 0
  spi_init:
    ret = int(exec(const_string($q), 0))
  return ret
