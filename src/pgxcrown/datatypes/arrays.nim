from basic import Oid, Datum
{.push header: "utils/array.h".}
type
  ArrayType*  {.importc.} = object
    vl_len {.importc: "vl_len_".}: int32
    ndim: int
    dataoffset: int32
    elemtype: Oid

proc DatumGetArrayTypeP*(x: Datum): ptr ArrayType {.importc.}
proc deconstruct_array_builtin*(arr: ptr ArrayType, elemtype: Oid, elemsp: ptr ptr Datum, nullsp: ptr ptr bool, nelemsp: var int) {.importc.}
{.pop.}
