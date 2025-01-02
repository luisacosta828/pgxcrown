from ../datatypes/basic import NameData, Oid, oidvector, Text

type 
  Form_pg_type* {.importc, header: "catalog/pg_type.h", incompletestruct.} = ptr object
    oid: Oid
    typname*: NameData
    padding1: array[8, byte]
    typlen*: int16
    padding2: array[5, byte]
    typdelim*: char
    padding3: array[45, byte]
    typstorage*: char
    padding4: array[17, byte]
    typdefaultbin: Text
    typdefault*: Text
