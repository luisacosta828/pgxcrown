import pgxcrown
import std/[options, strutils]

type
  {{type_name}}* {.pgxType: string.} = distinct string

proc parse_{{type_name}}*(s: cstring): {{type_name}} {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toUpperAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "{{type_name}} cannot be empty")
  if cleaned.len > 32:
    raise newException(ValueError, "{{type_name}} exceeds max length 32")
  {{type_name}}(cleaned)

proc format_{{type_name}}*(val: {{type_name}}): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc {{project_snake}}_prefix*(val: {{type_name}}): string {.immutable, parallelSafe.} =
  let s = string(val)
  let idx = s.find('-')
  if idx >= 0:
    return s[0 ..< idx]
  s

proc {{project_snake}}_opt_prefix*(val: Option[{{type_name}}]): Option[string] {.immutable, parallelSafe.} =
  if val.isNone:
    return none(string)
  some({{project_snake}}_prefix(val.get))

proc {{project_snake}}_coalesce_code*(val: Option[{{type_name}}], fallback: {{type_name}}): {{type_name}} {.immutable, parallelSafe.} =
  if val.isSome:
    return val.get
  fallback
