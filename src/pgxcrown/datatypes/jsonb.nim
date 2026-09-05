# =============================================================================
# pgxcrown - High Performance Zero-Copy Binary JSONB Module
# Direct C FFI over PostgreSQL <utils/jsonb.h>
# Compatible with PostgreSQL 13, 14, 15, 16, 17
# =============================================================================

import std/[json, strutils]
import ./basic

{.push header: "postgres.h".}
{.push header: "utils/jsonb.h".}

# -----------------------------------------------------------------------------
# 1. C-FFI Type Definitions from <utils/jsonb.h>
# -----------------------------------------------------------------------------
const
  jbvNull* = 0x0.cint
  jbvString* = 0x1.cint
  jbvNumeric* = 0x2.cint
  jbvBool* = 0x3.cint
  jbvArray* = 0x10.cint
  jbvObject* = 0x11.cint
  jbvBinary* = 0x12.cint
  jbvDatetime* = 0x20.cint

type
  JsonbContainer* {.importc: "JsonbContainer", bycopy.} = object
  
  JsonbStringVal* {.bycopy.} = object
    len*: cint
    val*: cstring

  JsonbBinaryVal* {.bycopy.} = object
    len*: cint
    data*: ptr JsonbContainer

  JsonbValUnion* {.union, bycopy.} = object
    numeric*: pointer
    boolean*: bool
    string*: JsonbStringVal
    binary*: JsonbBinaryVal

  JsonbValue* {.importc: "JsonbValue", bycopy.} = object
    `type`*: cint
    val*: JsonbValUnion

  Jsonb* {.importc: "Jsonb", bycopy.} = object
    vl_len: int32
    root*: JsonbContainer

  JsonbIterator* {.importc: "JsonbIterator".} = object
  JsonbIteratorToken* {.size: sizeof(cint).} = enum
    WJB_DONE = 0
    WJB_KEY
    WJB_VALUE
    WJB_ELEM
    WJB_BEGIN_ARRAY
    WJB_END_ARRAY
    WJB_BEGIN_OBJECT
    WJB_END_OBJECT

# -----------------------------------------------------------------------------
# 2. C Core Functions (PG 13 - 17)
# -----------------------------------------------------------------------------
proc DatumGetJsonbP*(d: Datum): ptr Jsonb {.importc: "DatumGetJsonbP".}

proc getKeyJsonValueFromContainer*(
  container: ptr JsonbContainer,
  keyVal: cstring,
  keyLen: cint,
  res: ptr JsonbValue
): ptr JsonbValue {.importc: "getKeyJsonValueFromContainer".}

proc getIthJsonbValueFromContainer*(
  container: ptr JsonbContainer,
  i: cuint
): ptr JsonbValue {.importc: "getIthJsonbValueFromContainer".}

proc JsonbIteratorInit*(container: ptr JsonbContainer): ptr JsonbIterator 
  {.importc: "JsonbIteratorInit".}

proc JsonbIteratorNext*(
  it: ptr ptr JsonbIterator,
  val: ptr JsonbValue,
  skipNested: bool
): JsonbIteratorToken {.importc: "JsonbIteratorNext".}

{.pop.} # utils/jsonb.h

{.push header: "utils/fmgrprotos.h".}
proc numeric_float8*(fcinfo: FunctionCallInfo): Datum {.importc: "numeric_float8", noconv, cdecl, noSideEffect, gcsafe.}
proc numeric_int4*(fcinfo: FunctionCallInfo): Datum {.importc: "numeric_int4", noconv, cdecl, noSideEffect, gcsafe.}
{.pop.}

{.pop.} # postgres.h

# -----------------------------------------------------------------------------
# 3. High-Level Ergonomic Zero-Copy Type: JsonbView
# -----------------------------------------------------------------------------
type
  JsonbView* = object
    container*: ptr JsonbContainer
    val*: JsonbValue
    found*: bool
    rawDatum*: Datum

proc initJsonbView*(d: Datum): JsonbView =
  if d == 0:
    return JsonbView(found: false, rawDatum: 0)
  let jb = DatumGetJsonbP(d)
  if jb == nil:
    return JsonbView(found: false, rawDatum: 0)
  result.container = addr jb.root
  result.found = true
  result.rawDatum = d
  result.val.`type` = jbvBinary
  result.val.val.binary.data = addr jb.root

proc isNull*(j: JsonbView): bool {.inline.} =
  not j.found or j.val.`type` == jbvNull

# Operador [] por clave (Objetos JSON)
proc `[]`*(j: JsonbView, key: string): JsonbView =
  if not j.found or j.container == nil:
    return JsonbView(found: false, rawDatum: 0)

  var res: JsonbValue
  let ptrRes = getKeyJsonValueFromContainer(j.container, key.cstring, key.len.cint, addr res)
  if ptrRes == nil:
    return JsonbView(found: false, rawDatum: 0)

  result.found = true
  result.val = res
  result.rawDatum = 0
  if res.`type` == jbvBinary:
    result.container = res.val.binary.data

# Operador [] por índice (Arrays JSON)
proc `[]`*(j: JsonbView, idx: int): JsonbView =
  if not j.found or j.container == nil or idx < 0:
    return JsonbView(found: false, rawDatum: 0)

  let ptrRes = getIthJsonbValueFromContainer(j.container, idx.cuint)
  if ptrRes == nil:
    return JsonbView(found: false, rawDatum: 0)

  result.found = true
  result.val = ptrRes[]
  result.rawDatum = 0
  if ptrRes.`type` == jbvBinary:
    result.container = ptrRes.val.binary.data

# Operador {} para navegación anidada profunda (ej: doc{"user", "tier"})
proc `{}`*(j: JsonbView, keys: varargs[string]): JsonbView =
  result = j
  for k in keys:
    result = result[k]
    if not result.found: return JsonbView(found: false, rawDatum: 0)

proc hasKey*(j: JsonbView, key: string): bool {.inline.} =
  j[key].found

# Extractores tipados con valores por defecto (compatibles con std/json)
proc getStr*(j: JsonbView, default = ""): string =
  if not j.found or j.val.`type` != jbvString: return default
  let length = j.val.val.string.len
  if length <= 0: return ""
  result = newString(length)
  copyMem(addr result[0], j.val.val.string.val, length)

proc getFloat*(j: JsonbView, default = 0.0): float =
  if not j.found: return default
  if j.val.`type` == jbvNumeric:
    if j.val.val.numeric == nil: return default
    return DirectFunctionCall1(numeric_float8, cast[Datum](j.val.val.numeric)).DatumGetFloat8
  elif j.val.`type` == jbvString:
    try: return parseFloat(j.getStr()) except CatchableError: return default
  return default

proc getInt*(j: JsonbView, default = 0): int =
  if not j.found: return default
  if j.val.`type` == jbvNumeric:
    if j.val.val.numeric == nil: return default
    return DirectFunctionCall1(numeric_int4, cast[Datum](j.val.val.numeric)).DatumGetInt32.int
  elif j.val.`type` == jbvString:
    try: return parseInt(j.getStr()) except CatchableError: return default
  return default

proc getBool*(j: JsonbView, default = false): bool =
  if not j.found or j.val.`type` != jbvBool: return default
  return j.val.val.boolean

# Iterador sobre arrays (Zero-Copy)
iterator items*(j: JsonbView): JsonbView =
  if j.found and j.container != nil:
    var it = JsonbIteratorInit(j.container)
    var val: JsonbValue
    let startTok = JsonbIteratorNext(addr it, addr val, true)
    if startTok == WJB_BEGIN_ARRAY:
      while true:
        let tok = JsonbIteratorNext(addr it, addr val, true)
        if tok == WJB_END_ARRAY or tok == WJB_DONE: break
        if tok in {WJB_ELEM, WJB_BEGIN_OBJECT, WJB_BEGIN_ARRAY}:
          var elem = JsonbView(found: true, val: val, rawDatum: 0)
          if val.`type` == jbvBinary:
            elem.container = val.val.binary.data
          yield elem

# -----------------------------------------------------------------------------
# Binary Streaming Deserializer from JsonbContainer to JsonNode
# -----------------------------------------------------------------------------
proc parseContainer*(container: ptr JsonbContainer): JsonNode =
  if container == nil: return newJNull()
  var it = JsonbIteratorInit(container)
  var val: JsonbValue
  let startTok = JsonbIteratorNext(addr it, addr val, true)
  
  case startTok
  of WJB_BEGIN_OBJECT:
    result = newJObject()
    while true:
      var keyVal: JsonbValue
      let kTok = JsonbIteratorNext(addr it, addr keyVal, true)
      if kTok == WJB_END_OBJECT or kTok == WJB_DONE: break
      if kTok == WJB_KEY:
        let kLen = keyVal.val.string.len
        var kStr = newString(kLen)
        if kLen > 0: copyMem(addr kStr[0], keyVal.val.string.val, kLen)
        
        var vVal: JsonbValue
        let vTok = JsonbIteratorNext(addr it, addr vVal, true)
        case vTok
        of WJB_VALUE, WJB_BEGIN_OBJECT, WJB_BEGIN_ARRAY:
          case vVal.`type`
          of jbvNull: result[kStr] = newJNull()
          of jbvBool: result[kStr] = newJBool(vVal.val.boolean)
          of jbvNumeric:
            if vVal.val.numeric == nil: result[kStr] = newJNull()
            else:
              let f = DirectFunctionCall1(numeric_float8, cast[Datum](vVal.val.numeric)).DatumGetFloat8
              if f == float64(f.BiggestInt): result[kStr] = newJInt(f.BiggestInt)
              else: result[kStr] = newJFloat(f)
          of jbvString:
            let sLen = vVal.val.string.len
            var s = newString(sLen)
            if sLen > 0: copyMem(addr s[0], vVal.val.string.val, sLen)
            result[kStr] = newJString(s)
          of jbvBinary:
            if vVal.val.binary.data != nil:
              result[kStr] = parseContainer(vVal.val.binary.data)
            else:
              result[kStr] = if vTok == WJB_BEGIN_ARRAY: newJArray() else: newJObject()
          else:
            result[kStr] = newJNull()
        else:
          result[kStr] = newJNull()

  of WJB_BEGIN_ARRAY:
    result = newJArray()
    while true:
      var elemVal: JsonbValue
      let eTok = JsonbIteratorNext(addr it, addr elemVal, true)
      if eTok == WJB_END_ARRAY or eTok == WJB_DONE: break
      case eTok
      of WJB_ELEM, WJB_BEGIN_OBJECT, WJB_BEGIN_ARRAY:
        case elemVal.`type`
        of jbvNull: result.add(newJNull())
        of jbvBool: result.add(newJBool(elemVal.val.boolean))
        of jbvNumeric:
          if elemVal.val.numeric == nil: result.add(newJNull())
          else:
            let f = DirectFunctionCall1(numeric_float8, cast[Datum](elemVal.val.numeric)).DatumGetFloat8
            if f == float64(f.BiggestInt): result.add(newJInt(f.BiggestInt))
            else: result.add(newJFloat(f))
        of jbvString:
          let sLen = elemVal.val.string.len
          var s = newString(sLen)
          if sLen > 0: copyMem(addr s[0], elemVal.val.string.val, sLen)
          result.add(newJString(s))
        of jbvBinary:
          if elemVal.val.binary.data != nil:
            result.add(parseContainer(elemVal.val.binary.data))
          else:
            result.add(if eTok == WJB_BEGIN_ARRAY: newJArray() else: newJObject())
        else:
          result.add(newJNull())
      else:
        discard

  of WJB_ELEM:
    case val.`type`
    of jbvNull: return newJNull()
    of jbvBool: return newJBool(val.val.boolean)
    of jbvNumeric:
      if val.val.numeric == nil: return newJNull()
      let f = DirectFunctionCall1(numeric_float8, cast[Datum](val.val.numeric)).DatumGetFloat8
      if f == float64(f.BiggestInt): return newJInt(f.BiggestInt)
      else: return newJFloat(f)
    of jbvString:
      let sLen = val.val.string.len
      var s = newString(sLen)
      if sLen > 0: copyMem(addr s[0], val.val.string.val, sLen)
      return newJString(s)
    else:
      return newJNull()
  else:
    return newJNull()

# Bridge hacia JsonNode (si el usuario quiere mutar o usar std/json)
proc toJsonNode*(j: JsonbView): JsonNode =
  if not j.found or j.isNull: return newJNull()
  if j.val.`type` == jbvBinary:
    return parseContainer(j.val.val.binary.data)
  elif j.container != nil:
    return parseContainer(j.container)
  else:
    case j.val.`type`
    of jbvString: return newJString(j.getStr())
    of jbvNumeric:
      let f = j.getFloat()
      if f == float64(f.BiggestInt): return newJInt(f.BiggestInt)
      else: return newJFloat(f)
    of jbvBool: return newJBool(j.getBool())
    else: return newJNull()


proc `$`*(j: JsonbView): string =
  if not j.found: return "null"
  return $j.toJsonNode()

# -----------------------------------------------------------------------------
# 4. Implicit Converters & Templates
# -----------------------------------------------------------------------------
converter DatumToJsonbView*(d: Datum): JsonbView {.inline.} =
  initJsonbView(d)

converter DatumToJsonNode*(x: Datum): JsonNode {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if x == 0: return newJNull()
      return initJsonbView(x).toJsonNode()

converter JsonNodeToDatum*(j: JsonNode): Datum {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if isNil(j) or j.kind == JNull:
        let csDatum = CStringToDatum("null")
        return DirectFunctionCall1(jsonb_in, csDatum)
      let csDatum = CStringToDatum(cstring($j))
      return DirectFunctionCall1(jsonb_in, csDatum)

converter JsonbViewToDatum*(j: JsonbView): Datum =
  if j.rawDatum != 0:
    return j.rawDatum
  return JsonNodeToDatum(j.toJsonNode())

template getJsonNode*(value: cuint): JsonNode =
  DatumToJsonNode(getDatum(value))

template getJsonbView*(value: cuint): JsonbView =
  initJsonbView(getDatum(value))

