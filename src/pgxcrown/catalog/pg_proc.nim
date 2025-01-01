from ../datatypes/basic import NameData, Oid, oidvector
type Form_pg_proc* {.importc, header: "catalog/pg_proc.h", incompletestruct.} = ptr object
  oid: Oid
  proname*: NameData
  #pronamespace*: Oid
  #proowner*: Oid
  #prolang*: Oid
  #procost*: float32
  #prorows*: float32
  #provariadic*: Oid
  #regproc*: Oid
  padding1: array[35, byte]
  pronargs*: int16
  pronargdefaults*: int16
  prorettype*: Oid
  proargtypes*: oidvector
