import std/[unittest, sets, json, hashes]
import ../src/pgxcrown/datatypes/[bytea, uuid]

suite "Pgxcrown - Zero-Copy NUL-Safe PgBytea & Native PgUuid Suite":

  test "PgBytea preserves embedded NUL bytes and binary length":
    let payload = @[0x00'u8, 0x41'u8, 0x00'u8, 0xff'u8, 0x00'u8]
    let b = toPgBytea(payload)
    check b.len == 5
    check not b.isEmpty()
    check b[0] == 0x00'u8
    check b[1] == 0x41'u8
    check b[2] == 0x00'u8
    check b[3] == 0xff'u8
    check b[4] == 0x00'u8
    check b.toBytes() == payload
    check b == payload
    check payload == b
    check $b == "\\x004100ff00"
    check toHexBytea(b, prefix = false) == "004100ff00"
    check %b == %("\\x004100ff00")

    var collected: seq[byte] = @[]
    for item in b:
      collected.add(item)
    check collected == payload

    let copied = b
    check copied == b
    check copied.toBytes() == payload

  test "PgBytea zero-copy borrowed view and slicing":
    var buf = @[0xde'u8, 0xad'u8, 0x00'u8, 0xbe'u8, 0xef'u8]
    let view = initPgByteaView(addr buf[0], buf.len)
    check view.len == 5
    check view[1 .. 3].toBytes() == @[0xad'u8, 0x00'u8, 0xbe'u8]
    check view[20 .. 5].isEmpty()
    check view.hash == toPgBytea(buf).hash

    let ownedSlice = toPgBytea(buf)[1 .. 3]
    check ownedSlice == @[0xad'u8, 0x00'u8, 0xbe'u8]
    check ownedSlice < toPgBytea(buf)

  test "PgBytea hex parsing and validation":
    let b1 = fromHexBytea("\\x00ff42")
    check b1.toBytes() == @[0x00'u8, 0xff'u8, 0x42'u8]

    let b2 = fromHexBytea("00FF42")
    check b1 == b2

    let bEmpty = fromHexBytea("\\x")
    check bEmpty.isEmpty()
    check $bEmpty == "\\x"

    expect(ValueError):
      discard fromHexBytea("\\x00f")
    expect(ValueError):
      discard fromHexBytea("\\x00zz")

  test "PgBytea string conversion and bounds defect":
    let b = toPgBytea("A\0B\0C")
    check b.len == 5
    check b.toRawString() == "A\0B\0C"
    expect(IndexDefect):
      discard b[5]

  test "PgUuid POD size, nilUuid, parsing, formatting, and version/variant":
    check sizeof(PgUuid) == 16

    let z = nilUuid()
    check z.isNilUuid()
    check $z == "00000000-0000-0000-0000-000000000000"

    let u1 = parsePgUuid("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11")
    let u2 = parsePgUuid("{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}")
    let u3 = parsePgUuid("a0eebc999c0b4ef8bb6d6bb9bd380a11")
    check u1 == u2
    check u2 == u3
    check $u1 == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
    check not u1.isNilUuid()
    check u1.version() == 4
    check u1.variant() == 2
    check %u1 == %"a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"

    let u7 = parsePgUuid("018f4230-1a2b-7c3d-8000-112233445566")
    check u7.version() == 7
    check u7.variant() == 2
    check z < u7
    check u7 < u1

  test "PgUuid HashSet deduplication and invalid input errors":
    var s = initHashSet[PgUuid]()
    let uA = parsePgUuid("550e8400-e29b-41d4-a716-446655440000")
    let uB = parsePgUuid("550E8400E29B41D4A716446655440000")
    let uC = parsePgUuid("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    s.incl(uA)
    s.incl(uB)
    s.incl(uC)
    check s.len == 2
    check uA in s
    check uC in s

    expect(ValueError):
      discard parsePgUuid("not-a-uuid")
    expect(ValueError):
      discard parsePgUuid("550e8400-e29b-41d4-a716-44665544000g")
    expect(ValueError):
      discard initPgUuid(@[1'u8, 2'u8, 3'u8])
