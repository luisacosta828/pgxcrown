import pgxcrown
import std/strutils

proc {{project_snake}}_hello*(target: string = "World"): string {.immutable, parallelSafe.} =
  "Hello, " & target & " from {{project_name}}!"

proc {{project_snake}}_add*(a, b: int32): int32 {.immutable, parallelSafe.} =
  a + b

proc {{project_snake}}_slugify*(raw: string): string {.immutable, parallelSafe.} =
  raw.strip().toLowerAscii().replace(" ", "-")
