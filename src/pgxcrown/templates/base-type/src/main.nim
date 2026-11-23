import pgxcrown
import std/strutils

type
  {{type_name}}* {.pgxType: string.} = distinct string

proc parse_{{type_name}}*(s: cstring): {{type_name}} {.pgxInput, immutable, parallelSafe.} =
  let cleaned = ($s).strip().toUpperAscii()
  if cleaned.len == 0:
    raise newException(ValueError, "{{type_name}} cannot be empty")
  {{type_name}}(cleaned)

proc format_{{type_name}}*(val: {{type_name}}): string {.pgxOutput, immutable, parallelSafe.} =
  string(val)

proc {{project_snake}}_prefix*(val: {{type_name}}): string {.immutable, parallelSafe.} =
  let s = string(val)
  let idx = s.find('-')
  if idx >= 0:
    return s[0 ..< idx]
  return s
