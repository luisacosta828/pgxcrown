from basic import Oid, Datum, NameData, OidOutputFunctionCall, PointerGetDatum, Pointer,
  Int32GetDatum, Int64GetDatum, Float4GetDatum, Float8GetDatum, BoolGetDatum,
  CharGetDatum, ObjectIdGetDatum, CStringGetTextDatum, DatumToInt32, DatumToInt64,
  DatumGetFloat8, DatumGetChar, DatumGetObjectId, DatumToCString,
  JsonNodeToDatum, DatumToJsonNode, DatumGetInt32, DatumGetInt64, DatumGetInt16,
  DatumGetFloat4

import std/[options, json, strutils, typetraits]

{.push header: "access/htup_details.h" .}
type
  DatumTupleFields {.importc: "struct DatumTupleFields".} = object
    datum_len*: int32
    datum_typmod*: int32
    datum_typeid*: Oid

  HeapTupleHeaderChoice {.importc: "union".} = object
    t_heap:  pointer
    t_datum*: DatumTupleFields

  HeapTupleHeaderData* {.importc: "HeapTupleHeaderData".} = object
    t_choice*:   HeapTupleHeaderChoice
    t_ctid*:     pointer # ItemPointerData
    t_infomask2*: uint16
    t_infomask*:  uint16
    t_hoff*:      uint8

  HeapTupleHeader* = ptr HeapTupleHeaderData 

  HeapTupleData* {.importc: "HeapTupleData".} = object
    t_len*: uint32
    t_self*: pointer
    t_tableOid*: Oid
    t_data*: HeapTupleHeader

  HeapTuple* = ptr HeapTupleData

  FormData_pg_attribute* {.importc: "FormData_pg_attribute".} = object
    attrelid*: Oid
    attname*: NameData
    atttypid*: Oid
    attnum*: int16
    attisdropped*: bool
  
  Form_pg_attribute* = ptr FormData_pg_attribute

proc heap_form_tuple*(tupleDescriptor: pointer, values: ptr Datum, isnull: ptr bool): HeapTuple {.importc: "heap_form_tuple".}
proc heap_freetuple*(htup: HeapTuple) {.importc: "heap_freetuple".}

{.pop.}

proc HeapTupleGetDatum*(htup: HeapTuple): Datum {.inline.} =
  if htup.isNil: return 0.Datum
  return PointerGetDatum(cast[Pointer](htup.t_data))

{.push header: "access/tupdesc.h".}
type
  TupleDesc* {.importc: "TupleDesc".} = pointer
  TupleDescData* {.importc: "struct TupleDescData".} = object
    natts*: cint

  TupleDescStruct* = ptr TupleDescData

proc DecrTupleDescRefCount*(tup: TupleDesc) {.importc.}
proc CreateTemplateTupleDesc*(natts: cint): TupleDesc {.importc: "CreateTemplateTupleDesc".}
proc TupleDescInitEntry*(desc: TupleDesc, attnum: int16, attname: cstring, oidtypeid: Oid, typmod: int32, attdim: cint) {.importc: "TupleDescInitEntry".}
proc BlessTupleDesc*(tupdesc: TupleDesc): TupleDesc {.importc: "BlessTupleDesc".}
proc TupleDescAttr*(tupdesc: TupleDesc, i: cint): Form_pg_attribute {.importc: "TupleDescAttr".}
{.pop.}

{.push header: "utils/typcache.h".}
proc lookup_rowtype_tupdesc*(type_id: Oid, typmod: cint): TupleDesc {.importc.}
proc lookup_rowtype_tupdesc_noerror*(type_id: Oid, typmod: int32, noError: bool): TupleDesc {.importc: "lookup_rowtype_tupdesc_noerror".}
{.pop.}

{.push header: "executor/executor.h" .}
proc GetAttributeByNum*(tup: HeapTupleHeader, attrno: cint, isNull: var bool): Datum {.importc.}
{.pop.}

{.push header: "fmgr.h".}
proc getHeapTupleHeader*(value: cuint): HeapTupleHeader {.importc: "PG_GETARG_HEAPTUPLEHEADER" .}
{.pop.}

proc get_tuple_attr*[T](element: HeapTupleHeader, row: TupleDesc, idx: cint): T =
  var isNull: bool
  if not row.isNil and not element.isNil:
    var attr = GetAttributeByNum(element, idx, isNull)
    if not isNull:
      result = attr
    else:
      result = default(T)

proc getTypeId*(tup: HeapTupleHeader): Oid =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typeid
  return 0.Oid

proc getTypeMod*(tup: HeapTupleHeader): cint =
  if not tup.isNil:
    return tup.t_choice.t_datum.datum_typmod
  return -1

{.push header: "utils/lsyscache.h".}
proc getTypeOutputInfo*(typeId: Oid, typOutput: var Oid, typIsVarlena: var bool) {.importc: "getTypeOutputInfo".}
{.pop.}

proc getTupleDesc*(heapTuple: HeapTupleHeader): TupleDesc {. inline .} =
  var 
    tupTypeId = getTypeId(heapTuple)
    tupTypMod = getTypeMod(heapTuple)
  
  result = lookup_rowtype_tupdesc(tupTypeId, tupTypMod)

proc getTupleStringAttr*(element: HeapTupleHeader, row: TupleDesc, idx: cint): cstring =
  var isNull: bool
  if not row.isNil and not element.isNil:
    let d = GetAttributeByNum(element, idx, isNull)
    if not isNull and d != 0:
      let attr = TupleDescAttr(row, idx - 1)
      if attr != nil:
        var outputProc: Oid
        var isVarlena: bool
        getTypeOutputInfo(attr.atttypid, outputProc, isVarlena)
        if outputProc != 0:
          return OidOutputFunctionCall(outputProc, d)
  return ""

# -----------------------------------------------------------------------------
# High-Level Generic Deserializer: HeapTupleHeader -> object
# -----------------------------------------------------------------------------

proc tupleHeaderToObject*[T: object | tuple](th: HeapTupleHeader): T {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      if th.isNil: return default(T)
      let tupDesc = getTupleDesc(th)
      if tupDesc.isNil: return default(T)

      var idx: cint = 1
  for name, field in fieldPairs(result):
    var isNull: bool
    let rawDatum = GetAttributeByNum(th, idx, isNull)
    if isNull or rawDatum == 0:
      when typeof(field) is Option:
        field = none(typeof(field.get))
      else:
        field = default(typeof(field))
    else:
      when typeof(field) is Option:
        type InnerT = typeof(field.get)
        var innerVal: InnerT
        when InnerT is bool: innerVal = (rawDatum != 0)
        elif InnerT is int8: innerVal = int8(rawDatum)
        elif InnerT is int16 or InnerT is cshort: innerVal = InnerT(DatumGetInt16(rawDatum))
        elif InnerT is int32 or InnerT is cint or InnerT is int: innerVal = InnerT(DatumGetInt32(rawDatum))
        elif InnerT is int64 or InnerT is clonglong: innerVal = InnerT(DatumGetInt64(rawDatum))
        elif InnerT is uint32 or InnerT is cuint: innerVal = InnerT(DatumGetObjectId(rawDatum))
        elif InnerT is float32 or InnerT is cfloat: innerVal = InnerT(DatumGetFloat4(rawDatum))
        elif InnerT is float64 or InnerT is cdouble or InnerT is float: innerVal = InnerT(DatumGetFloat8(rawDatum))
        elif InnerT is string:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          innerVal = if cs != nil: $cs else: ""
        elif InnerT is cstring:
          innerVal = getTupleStringAttr(th, tupDesc, idx)
        elif InnerT is char:
          innerVal = DatumGetChar(rawDatum)
        elif InnerT is JsonNode:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          if cs != nil and cs.len > 0:
            {.cast(noSideEffect).}:
              {.cast(tags: []).}:
                try: innerVal = parseJson($cs)
                except CatchableError: innerVal = newJNull()
          else:
            innerVal = newJNull()
        elif InnerT is enum:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          if cs != nil:
            try: innerVal = parseEnum[InnerT]($cs)
            except CatchableError: innerVal = default(InnerT)
        else:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          innerVal = if cs != nil: $cs else: ""
        field = some(innerVal)
      else:
        when typeof(field) is bool: field = (rawDatum != 0)
        elif typeof(field) is int8: field = int8(rawDatum)
        elif typeof(field) is int16 or typeof(field) is cshort: field = typeof(field)(DatumGetInt16(rawDatum))
        elif typeof(field) is int32 or typeof(field) is cint or typeof(field) is int: field = typeof(field)(DatumGetInt32(rawDatum))
        elif typeof(field) is int64 or typeof(field) is clonglong: field = typeof(field)(DatumGetInt64(rawDatum))
        elif typeof(field) is uint32 or typeof(field) is cuint: field = typeof(field)(DatumGetObjectId(rawDatum))
        elif typeof(field) is float32 or typeof(field) is cfloat: field = typeof(field)(DatumGetFloat4(rawDatum))
        elif typeof(field) is float64 or typeof(field) is cdouble or typeof(field) is float: field = typeof(field)(DatumGetFloat8(rawDatum))
        elif typeof(field) is distinct:
          when distinctBase(typeof(field)) is int64: field = typeof(field)(DatumGetInt64(rawDatum))
          elif distinctBase(typeof(field)) is int32: field = typeof(field)(DatumGetInt32(rawDatum))
          elif distinctBase(typeof(field)) is int16: field = typeof(field)(DatumGetInt16(rawDatum))
          elif distinctBase(typeof(field)) is uint32: field = typeof(field)(DatumGetObjectId(rawDatum))
          elif distinctBase(typeof(field)) is float64: field = typeof(field)(DatumGetFloat8(rawDatum))
          elif distinctBase(typeof(field)) is float32: field = typeof(field)(DatumGetFloat4(rawDatum))
          else: field = default(typeof(field))
        elif typeof(field) is string:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          field = if cs != nil: $cs else: ""
        elif typeof(field) is cstring:
          field = getTupleStringAttr(th, tupDesc, idx)
        elif typeof(field) is char:
          field = DatumGetChar(rawDatum)
        elif typeof(field) is JsonNode:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          if cs != nil and cs.len > 0:
            {.cast(noSideEffect).}:
              {.cast(tags: []).}:
                try: field = parseJson($cs)
                except CatchableError: field = newJNull()
          else:
            field = newJNull()
        elif typeof(field) is enum:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          if cs != nil:
            try: field = parseEnum[typeof(field)]($cs)
            except CatchableError: field = default(typeof(field))
        else:
          let cs = getTupleStringAttr(th, tupDesc, idx)
          field = if cs != nil: $cs else: ""
    idx += 1

  DecrTupleDescRefCount(tupDesc)

# -----------------------------------------------------------------------------
# High-Level Generic Serializer: object -> HeapTuple / Datum
# -----------------------------------------------------------------------------

proc buildTupleDescFor*[T: object | tuple](): TupleDesc =
  var numFields: cint = 0
  var dummy: T
  for name, val in fieldPairs(dummy):
    numFields += 1
  
  if numFields == 0: return nil
  let desc = CreateTemplateTupleDesc(numFields)
  var attrNum: int16 = 1
  for name, val in fieldPairs(dummy):
    let oid: Oid = when typeof(val) is bool: 16.Oid
                   elif typeof(val) is int8: 18.Oid
                   elif typeof(val) is int16 or typeof(val) is cshort: 21.Oid
                   elif typeof(val) is int32 or typeof(val) is cint or typeof(val) is int: 23.Oid
                   elif typeof(val) is int64 or typeof(val) is clonglong: 20.Oid
                   elif typeof(val) is uint32 or typeof(val) is cuint: 26.Oid
                   elif typeof(val) is float32 or typeof(val) is cfloat: 700.Oid
                   elif typeof(val) is float64 or typeof(val) is cdouble or typeof(val) is float: 701.Oid
                   elif typeof(val) is distinct:
                     when distinctBase(typeof(val)) is int64: 20.Oid
                     elif distinctBase(typeof(val)) is int32: 23.Oid
                     elif distinctBase(typeof(val)) is int16: 21.Oid
                     elif distinctBase(typeof(val)) is uint32: 26.Oid
                     elif distinctBase(typeof(val)) is float64: 701.Oid
                     elif distinctBase(typeof(val)) is float32: 700.Oid
                     else: 25.Oid
                   elif typeof(val) is string or typeof(val) is cstring: 25.Oid
                   elif typeof(val) is char: 18.Oid
                   elif typeof(val) is JsonNode: 3802.Oid
                   elif typeof(val) is Option:
                     when typeof(val.get) is bool: 16.Oid
                     elif typeof(val.get) is int8: 18.Oid
                     elif typeof(val.get) is int16 or typeof(val.get) is cshort: 21.Oid
                     elif typeof(val.get) is int32 or typeof(val.get) is cint or typeof(val.get) is int: 23.Oid
                     elif typeof(val.get) is int64 or typeof(val.get) is clonglong: 20.Oid
                     elif typeof(val.get) is uint32 or typeof(val.get) is cuint: 26.Oid
                     elif typeof(val.get) is float32 or typeof(val.get) is cfloat: 700.Oid
                     elif typeof(val.get) is float64 or typeof(val.get) is cdouble or typeof(val.get) is float: 701.Oid
                     elif typeof(val.get) is distinct:
                       when distinctBase(typeof(val.get)) is int64: 20.Oid
                       elif distinctBase(typeof(val.get)) is int32: 23.Oid
                       elif distinctBase(typeof(val.get)) is int16: 21.Oid
                       elif distinctBase(typeof(val.get)) is uint32: 26.Oid
                       elif distinctBase(typeof(val.get)) is float64: 701.Oid
                       elif distinctBase(typeof(val.get)) is float32: 700.Oid
                       else: 25.Oid
                     elif typeof(val.get) is string or typeof(val.get) is cstring: 25.Oid
                     elif typeof(val.get) is char: 18.Oid
                     elif typeof(val.get) is JsonNode: 3802.Oid
                     else: 25.Oid
                   else: 25.Oid
    TupleDescInitEntry(desc, attrNum, cstring(name), oid, -1'i32, 0'i32)
    attrNum += 1
  return BlessTupleDesc(desc)

proc objectToHeapTuple*[T: object | tuple](obj: T, customDesc: TupleDesc = nil): HeapTuple {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let tupDesc = if customDesc != nil: customDesc else: buildTupleDescFor[T]()
      if tupDesc.isNil: return nil

      var numFields: cint = 0
      for name, val in fieldPairs(obj):
        numFields += 1

      if numFields == 0: return nil
      var values = newSeq[Datum](numFields)
      var nulls = newSeq[bool](numFields)

      var idx = 0
      for name, val in fieldPairs(obj):
        when typeof(val) is Option:
          if val.isNone:
            nulls[idx] = true
            values[idx] = 0.Datum
          else:
            nulls[idx] = false
            let innerVal = val.get
            when typeof(innerVal) is bool: values[idx] = if innerVal: 1.Datum else: 0.Datum
            elif typeof(innerVal) is int8: values[idx] = Datum(innerVal)
            elif typeof(innerVal) is int16 or typeof(innerVal) is cshort: values[idx] = Datum(innerVal)
            elif typeof(innerVal) is int32 or typeof(innerVal) is cint or typeof(innerVal) is int: values[idx] = Int32GetDatum(int32(innerVal))
            elif typeof(innerVal) is int64 or typeof(innerVal) is clonglong: values[idx] = Int64GetDatum(int64(innerVal))
            elif typeof(innerVal) is uint32 or typeof(innerVal) is cuint: values[idx] = ObjectIdGetDatum(Oid(innerVal))
            elif typeof(innerVal) is float32 or typeof(innerVal) is cfloat: values[idx] = Float4GetDatum(float32(innerVal))
            elif typeof(innerVal) is float64 or typeof(innerVal) is cdouble or typeof(innerVal) is float: values[idx] = Float8GetDatum(float64(innerVal))
            elif typeof(innerVal) is distinct:
              when distinctBase(typeof(innerVal)) is int64: values[idx] = Int64GetDatum(int64(innerVal))
              elif distinctBase(typeof(innerVal)) is int32: values[idx] = Int32GetDatum(int32(innerVal))
              elif distinctBase(typeof(innerVal)) is int16: values[idx] = Int16GetDatum(int16(innerVal))
              elif distinctBase(typeof(innerVal)) is uint32: values[idx] = ObjectIdGetDatum(Oid(uint32(innerVal)))
              elif distinctBase(typeof(innerVal)) is float64: values[idx] = Float8GetDatum(float64(innerVal))
              elif distinctBase(typeof(innerVal)) is float32: values[idx] = Float4GetDatum(float32(innerVal))
              else: values[idx] = Datum(0)
            elif typeof(innerVal) is string: values[idx] = CStringGetTextDatum(cstring(innerVal))
            elif typeof(innerVal) is cstring: values[idx] = CStringGetTextDatum(innerVal)
            elif typeof(innerVal) is char: values[idx] = CharGetDatum(innerVal)
            elif typeof(innerVal) is JsonNode: values[idx] = JsonNodeToDatum(innerVal)
            elif typeof(innerVal) is enum: values[idx] = CStringGetTextDatum(cstring($innerVal))
            else: values[idx] = CStringGetTextDatum(cstring($innerVal))
        else:
          nulls[idx] = false
          when typeof(val) is bool: values[idx] = if val: 1.Datum else: 0.Datum
          elif typeof(val) is int8: values[idx] = Datum(val)
          elif typeof(val) is int16 or typeof(val) is cshort: values[idx] = Datum(val)
          elif typeof(val) is int32 or typeof(val) is cint or typeof(val) is int: values[idx] = Int32GetDatum(int32(val))
          elif typeof(val) is int64 or typeof(val) is clonglong: values[idx] = Int64GetDatum(int64(val))
          elif typeof(val) is uint32 or typeof(val) is cuint: values[idx] = ObjectIdGetDatum(Oid(val))
          elif typeof(val) is float32 or typeof(val) is cfloat: values[idx] = Float4GetDatum(float32(val))
          elif typeof(val) is float64 or typeof(val) is cdouble or typeof(val) is float: values[idx] = Float8GetDatum(float64(val))
          elif typeof(val) is distinct:
            when distinctBase(typeof(val)) is int64: values[idx] = Int64GetDatum(int64(val))
            elif distinctBase(typeof(val)) is int32: values[idx] = Int32GetDatum(int32(val))
            elif distinctBase(typeof(val)) is int16: values[idx] = Int16GetDatum(int16(val))
            elif distinctBase(typeof(val)) is uint32: values[idx] = ObjectIdGetDatum(Oid(uint32(val)))
            elif distinctBase(typeof(val)) is float64: values[idx] = Float8GetDatum(float64(val))
            elif distinctBase(typeof(val)) is float32: values[idx] = Float4GetDatum(float32(val))
            else: values[idx] = Datum(0)
          elif typeof(val) is string: values[idx] = CStringGetTextDatum(cstring(val))
          elif typeof(val) is cstring: values[idx] = CStringGetTextDatum(val)
          elif typeof(val) is char: values[idx] = CharGetDatum(val)
          elif typeof(val) is JsonNode: values[idx] = JsonNodeToDatum(val)
          elif typeof(val) is enum: values[idx] = CStringGetTextDatum(cstring($val))
          else: values[idx] = CStringGetTextDatum(cstring($val))
        idx += 1

      let htup = heap_form_tuple(tupDesc, cast[ptr Datum](addr values[0]), cast[ptr bool](addr nulls[0]))
      return htup

proc objectToDatum*[T: object | tuple](obj: T, customDesc: TupleDesc = nil): Datum {.tags: [].} =
  {.cast(noSideEffect).}:
    {.cast(tags: []).}:
      let htup = objectToHeapTuple[T](obj, customDesc)
      if htup.isNil: return 0.Datum
      return HeapTupleGetDatum(htup)

proc objectToDatum*[T: distinct](obj: T): Datum {.tags: [].} =
  when distinctBase(T) is int64: Int64GetDatum(int64(obj))
  elif distinctBase(T) is int32: Int32GetDatum(int32(obj))
  elif distinctBase(T) is int16: Int16GetDatum(int16(obj))
  elif distinctBase(T) is uint32: ObjectIdGetDatum(Oid(uint32(obj)))
  elif distinctBase(T) is float64: Float8GetDatum(float64(obj))
  elif distinctBase(T) is float32: Float4GetDatum(float32(obj))
  else: Datum(0)

