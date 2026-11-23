import pgxcrown
import std/[options, strutils]

proc ex02_greet_default*(name: string = "World", timesCount: int32 = 1): string {.immutable, parallelSafe.} =
  if timesCount < 1'i32:
    raise newException(ValueError, "timesCount must be >= 1")
  "Hello " & name & " x" & $timesCount

proc ex02_safe_divide*(num: int32, den: Option[int32] = none(int32)): Option[int32] {.immutable, parallelSafe.} =
  if den.isNone:
    return none(int32)
  if den.get == 0'i32:
    raisePgError("22012", "division by zero in ex02_safe_divide", hint = "Pass a non-zero divisor or NULL")
  some(num div den.get)

proc ex02_coalesce_label*(label: string, fallback: string = "anonymous"): string {.calledOnNullInput, immutable, parallelSafe.} =
  let cleanLabel = label.strip()
  if cleanLabel.len > 0:
    return cleanLabel
  let cleanFallback = fallback.strip()
  if cleanFallback.len > 0:
    return cleanFallback
  "anonymous"

proc ex02_validate_port*(port: int32): int32 {.immutable, parallelSafe.} =
  if port < 1'i32 or port > 65535'i32:
    raise newException(ValueError, "port must be between 1 and 65535")
  port

proc ex02_require_tag*(tag: string): string {.immutable, parallelSafe.} =
  let cleaned = tag.strip()
  if cleaned.len == 0:
    raisePgError("22023", "tag cannot be empty", hint = "Pass a non-blank string")
  cleaned.toUpperAscii()

proc ex02_checked_add*(a, b: int32): int32 {.immutable, parallelSafe.} =
  a + b

proc ex02_pick_item*(idx: int32): string {.immutable, parallelSafe.} =
  let items = ["alpha", "beta", "gamma"]
  items[idx]
