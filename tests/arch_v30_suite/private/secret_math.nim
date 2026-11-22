# Pure Nim internal module in `private/` — intentionally omitted from
# PostgreSQL SQL/C generation (no `import pgxcrown`, no `{.noSql.}` needed).

type
  PrivateCounter = object
    value: int32

  PrivateExportedBuffer* = object
    raw*: int32

proc secretScale*(x, factor: int32): int32 =
  let base = PrivateCounter(value: x)
  var buf = PrivateExportedBuffer(raw: base.value * factor)
  result = buf.raw
