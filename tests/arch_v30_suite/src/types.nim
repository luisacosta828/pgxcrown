import pgxcrown

type
  ArchStatus* = enum
    asPending = "pending",
    asActive = "active",
    asArchived = "archived"

  ArchItem* = object
    id*: int32
    label*: string
    status*: ArchStatus

  NoSqlBuffer* {.noSql.} = object
    raw*: int32

  InternalTypeOnly = object
    hiddenVal: int32

var typesInitStep*: int32 = 0

proc initTypesModule() {.pgxInit.} =
  let tmp = InternalTypeOnly(hiddenVal: 10)
  let buf = NoSqlBuffer(raw: tmp.hiddenVal)
  typesInitStep = buf.raw

proc srcNoSqlAdd*(a, b: int32): int32 {.noSql.} =
  a + b
