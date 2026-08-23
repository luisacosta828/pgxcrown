import pgxcrown
import std/[options, json]

# -----------------------------------------------------------------------------
# 📦 Pgxcrown JSON & JSONB (v0.17.0) Test Suite
# Tests JsonNode parameter extraction, return values, Option[JsonNode], and defaults
# -----------------------------------------------------------------------------

# Test 1: JSONB input and JSONB output (Enrichment)
proc json_enrich*(payload: JsonNode): JsonNode =
  result = payload.copy()
  result["processed"] = %true
  result["server_version"] = %"v0.17.0"

# Test 2: JSON key extraction as string
proc json_get_str*(doc: JsonNode, key: string): string =
  if doc.hasKey(key):
    return doc[key].getStr
  return ""

# Test 3: Null-safe Option[JsonNode] parameter and return
proc json_safe_transform*(val: Option[JsonNode]): Option[JsonNode] =
  if val.isNone:
    return none(JsonNode)
  var node = val.get.copy()
  node["transformed"] = %true
  return some(node)

# Test 4: Default JsonNode parameter
proc json_with_defaults*(cfg: JsonNode = %*{"mode": "default", "active": true}): JsonNode =
  return cfg

# Test 5: Sequence of JSON nodes (SETOF jsonb / jsonb[])
proc json_extract_items*(doc: JsonNode): seq[JsonNode] =
  result = @[]
  if doc.kind == JArray:
    for item in doc.items:
      result.add(item)
  elif doc.kind == JObject:
    for k, v in doc.pairs:
      result.add(%*{"key": k, "value": v})
