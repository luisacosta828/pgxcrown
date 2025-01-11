{.push header: "utils/array.h".}
type
  ArrayType*  {.importc.} = object
    vl_len* {.importc: "vl_len_".}: int32
    ndim*: int
    dataoffset*: int32
    elemtype*: cuint

proc DatumGetArrayTypeP*(x: cuint): ptr ArrayType {.importc.}
proc deconstruct_array_builtin*(arr: ptr ArrayType, elemtype: cuint, elemsp: ptr ptr cuint, nullsp: ptr ptr bool, nelemsp: var int) {.importc.}
proc deconstruct_array*(arr: ptr ArrayType, elemtype: cuint, elmlen: cint, elmbyval: bool, elmalign: char, elemsp: ptr ptr cuint, nullsp: ptr ptr bool, nelemsp: var int) {.importc.}
{.pop.}
