from basic import Oid
{.push header: "utils/arrays.h".}
type
  ArrayType*  {.importc.} = object
    vl_len {.importc: "vl_len_".}: int32
    ndim: int
    dataoffset: int32
    elemtype: Oid
{.pop.}
