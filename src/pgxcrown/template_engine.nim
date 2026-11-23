## =============================================================================
## Pgxcrown Project Template Engine (Pure Nim Stdlib, Zero libpcre)
## =============================================================================
## Provides:
##   1. Pure-Nim Thompson NFA regex engine for `template.json` variable patterns
##   2. Compile-time embedded builtin templates (`staticRead`) + external template
##      discovery (`$PGXTOOL_HOME/templates/<name>` and `--template ./dir`)
##   3. Strict path, symlink, NUL/control-char, and SemVer security hardening
##   4. Single-pass `{{placeholder}}` rendering and project scaffolding
## =============================================================================

import std/[algorithm, json, os, sets, strutils, tables]

type
  TemplateVarDef* = object
    name*: string
    defaultVal*: string
    pattern*: string

  TemplateFileEntry* = object
    srcRel*: string
    destRel*: string

  TemplateManifest* = object
    name*: string
    description*: string
    minPgxcrownVersion*: string
    variables*: seq[TemplateVarDef]
    files*: seq[TemplateFileEntry]

  TemplateSummary* = object
    name*: string
    description*: string
    minPgxcrownVersion*: string
    sourceKind*: string ## "builtin" or "external"
    sourcePath*: string
    variables*: seq[TemplateVarDef]

  LoadedTemplate = object
    manifest: TemplateManifest
    sourceKind: string
    sourceDir: string
    embeddedFiles: Table[string, string]

  ScaffoldResult* = object
    templateName*: string
    sourceKind*: string
    destDir*: string
    projectName*: string
    projectSnake*: string
    writtenFiles*: seq[string]

# =============================================================================
# 1. Pure-Nim Thompson NFA Regex Engine (No std/re, No libpcre)
# =============================================================================
# Supports: ^, $, ., [...], [^...], *, +, ?, {m}, {m,}, {m,n},
#           \d, \D, \w, \W, \s, \S, \., escapes, grouping (...)/(?:...), a|b

type
  RegexNodeKind = enum
    rnEmpty
    rnCharSet
    rnAnchorStart
    rnAnchorEnd
    rnConcat
    rnAlt
    rnRepeat

  RegexNode = ref object
    case kind: RegexNodeKind
    of rnEmpty, rnAnchorStart, rnAnchorEnd:
      discard
    of rnCharSet:
      charSet: set[char]
    of rnConcat, rnAlt:
      children: seq[RegexNode]
    of rnRepeat:
      child: RegexNode
      minCount: int
      maxCount: int ## -1 means unbounded

  RegexParser = object
    pattern: string
    pos: int

const
  AllChars = {low(char) .. high(char)}
  AnyExceptNewline = AllChars - {'\n'}
  DigitChars = {'0'..'9'}
  WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  SpaceChars = {' ', '\t', '\r', '\n', '\f', '\v'}
  MaxRegexRepeatBound = 256

proc escapeCharSet(ch: char): set[char] =
  case ch
  of 'd': DigitChars
  of 'D': AllChars - DigitChars
  of 'w': WordChars
  of 'W': AllChars - WordChars
  of 's': SpaceChars
  of 'S': AllChars - SpaceChars
  of 'n': {'\n'}
  of 'r': {'\r'}
  of 't': {'\t'}
  else: {ch}

proc parseCharClass(p: var RegexParser): RegexNode =
  inc p.pos # consume '['
  var negated = false
  if p.pos < p.pattern.len and p.pattern[p.pos] == '^':
    negated = true
    inc p.pos

  var cs: set[char] = {}
  var first = true
  var closed = false

  while p.pos < p.pattern.len:
    let ch = p.pattern[p.pos]
    if ch == ']' and not first:
      inc p.pos
      closed = true
      break
    first = false

    if ch == '\\':
      inc p.pos
      if p.pos >= p.pattern.len:
        raise newException(ValueError, "Unterminated escape inside regex character class")
      let esc = p.pattern[p.pos]
      inc p.pos
      if esc in {'d', 'D', 'w', 'W', 's', 'S'}:
        cs = cs + escapeCharSet(esc)
      else:
        let lit =
          case esc
          of 'n': '\n'
          of 'r': '\r'
          of 't': '\t'
          else: esc
        if p.pos + 1 < p.pattern.len and p.pattern[p.pos] == '-' and p.pattern[p.pos + 1] != ']':
          inc p.pos # consume '-'
          var endCh = p.pattern[p.pos]
          if endCh == '\\':
            inc p.pos
            if p.pos >= p.pattern.len:
              raise newException(ValueError, "Unterminated range end escape in regex class")
            endCh = p.pattern[p.pos]
          inc p.pos
          if ord(lit) > ord(endCh):
            raise newException(ValueError, "Invalid descending range in regex character class")
          cs = cs + {lit .. endCh}
        else:
          cs.incl(lit)
    else:
      inc p.pos
      if p.pos + 1 < p.pattern.len and p.pattern[p.pos] == '-' and p.pattern[p.pos + 1] != ']':
        inc p.pos # consume '-'
        var endCh = p.pattern[p.pos]
        if endCh == '\\':
          inc p.pos
          if p.pos >= p.pattern.len:
            raise newException(ValueError, "Unterminated range end escape in regex class")
          let escEnd = p.pattern[p.pos]
          if escEnd in {'d', 'D', 'w', 'W', 's', 'S'}:
            raise newException(ValueError, "Cannot use shorthand class in character range")
          endCh =
            case escEnd
            of 'n': '\n'
            of 'r': '\r'
            of 't': '\t'
            else: escEnd
        inc p.pos
        if ord(ch) > ord(endCh):
          raise newException(ValueError, "Invalid descending range '" & ch & "-" & endCh & "' in regex")
        cs = cs + {ch .. endCh}
      else:
        cs.incl(ch)

  if not closed:
    raise newException(ValueError, "Unclosed '[' in regex pattern: " & p.pattern)
  if negated:
    cs = AllChars - cs
  RegexNode(kind: rnCharSet, charSet: cs)

proc parseRegexAlt(p: var RegexParser): RegexNode

proc parseBraceQuantifier(p: var RegexParser): (int, int) =
  inc p.pos # consume '{'
  let startMin = p.pos
  while p.pos < p.pattern.len and p.pattern[p.pos] in DigitChars:
    inc p.pos
  if p.pos == startMin:
    raise newException(ValueError, "Invalid '{...}' quantifier in regex pattern: " & p.pattern)
  let minVal = parseInt(p.pattern[startMin ..< p.pos])
  if minVal > MaxRegexRepeatBound:
    raise newException(ValueError, "Regex quantifier lower bound exceeds " & $MaxRegexRepeatBound)

  var maxVal = minVal
  if p.pos < p.pattern.len and p.pattern[p.pos] == ',':
    inc p.pos
    if p.pos < p.pattern.len and p.pattern[p.pos] == '}':
      maxVal = -1
    else:
      let startMax = p.pos
      while p.pos < p.pattern.len and p.pattern[p.pos] in DigitChars:
        inc p.pos
      if p.pos == startMax:
        raise newException(ValueError, "Invalid upper bound in regex '{m,n}' quantifier")
      maxVal = parseInt(p.pattern[startMax ..< p.pos])
      if maxVal > MaxRegexRepeatBound:
        raise newException(ValueError, "Regex quantifier upper bound exceeds " & $MaxRegexRepeatBound)
      if maxVal < minVal:
        raise newException(ValueError, "Regex quantifier max < min in '{" & $minVal & "," & $maxVal & "}'")

  if p.pos >= p.pattern.len or p.pattern[p.pos] != '}':
    raise newException(ValueError, "Unclosed '{' quantifier in regex pattern: " & p.pattern)
  inc p.pos
  (minVal, maxVal)

proc parseRegexAtom(p: var RegexParser): RegexNode =
  let ch = p.pattern[p.pos]
  case ch
  of '^':
    inc p.pos
    RegexNode(kind: rnAnchorStart)
  of '$':
    inc p.pos
    RegexNode(kind: rnAnchorEnd)
  of '.':
    inc p.pos
    RegexNode(kind: rnCharSet, charSet: AnyExceptNewline)
  of '[':
    parseCharClass(p)
  of '(':
    inc p.pos
    if p.pos + 1 < p.pattern.len and p.pattern[p.pos] == '?' and p.pattern[p.pos + 1] == ':':
      p.pos += 2
    let inner = parseRegexAlt(p)
    if p.pos >= p.pattern.len or p.pattern[p.pos] != ')':
      raise newException(ValueError, "Unclosed '(' in regex pattern: " & p.pattern)
    inc p.pos
    inner
  of '\\':
    inc p.pos
    if p.pos >= p.pattern.len:
      raise newException(ValueError, "Trailing '\\' in regex pattern: " & p.pattern)
    let esc = p.pattern[p.pos]
    inc p.pos
    RegexNode(kind: rnCharSet, charSet: escapeCharSet(esc))
  of '*', '+', '?', '{':
    raise newException(ValueError, "Quantifier '" & ch & "' with no preceding atom in regex: " & p.pattern)
  of ')', '|':
    raise newException(ValueError, "Unexpected '" & ch & "' in regex atom: " & p.pattern)
  else:
    inc p.pos
    RegexNode(kind: rnCharSet, charSet: {ch})

proc parseRegexPiece(p: var RegexParser): RegexNode =
  result = parseRegexAtom(p)
  while p.pos < p.pattern.len:
    let q = p.pattern[p.pos]
    case q
    of '*':
      inc p.pos
      if p.pos < p.pattern.len and p.pattern[p.pos] == '?': inc p.pos
      result = RegexNode(kind: rnRepeat, child: result, minCount: 0, maxCount: -1)
    of '+':
      inc p.pos
      if p.pos < p.pattern.len and p.pattern[p.pos] == '?': inc p.pos
      result = RegexNode(kind: rnRepeat, child: result, minCount: 1, maxCount: -1)
    of '?':
      inc p.pos
      if p.pos < p.pattern.len and p.pattern[p.pos] == '?': inc p.pos
      result = RegexNode(kind: rnRepeat, child: result, minCount: 0, maxCount: 1)
    of '{':
      let (minC, maxC) = parseBraceQuantifier(p)
      if p.pos < p.pattern.len and p.pattern[p.pos] == '?': inc p.pos
      result = RegexNode(kind: rnRepeat, child: result, minCount: minC, maxCount: maxC)
    else:
      break

proc parseRegexConcat(p: var RegexParser): RegexNode =
  var items: seq[RegexNode] = @[]
  while p.pos < p.pattern.len:
    let ch = p.pattern[p.pos]
    if ch == '|' or ch == ')':
      break
    items.add(parseRegexPiece(p))
  if items.len == 0:
    RegexNode(kind: rnEmpty)
  elif items.len == 1:
    items[0]
  else:
    RegexNode(kind: rnConcat, children: items)

proc parseRegexAlt(p: var RegexParser): RegexNode =
  var branches: seq[RegexNode] = @[parseRegexConcat(p)]
  while p.pos < p.pattern.len and p.pattern[p.pos] == '|':
    inc p.pos
    branches.add(parseRegexConcat(p))
  if branches.len == 1:
    branches[0]
  else:
    RegexNode(kind: rnAlt, children: branches)

type
  NfaEdgeKind = enum
    nekEps
    nekStartAnchor
    nekEndAnchor
    nekChar

  NfaEdge = object
    kind: NfaEdgeKind
    target: int
    chars: set[char]

  NfaState = object
    edges: seq[NfaEdge]

  NfaFrag = object
    start: int
    accept: int

  CompiledRegex = object
    states: seq[NfaState]
    start: int
    accept: int

proc addState(states: var seq[NfaState]): int =
  result = states.len
  states.add(NfaState(edges: @[]))

proc addEdge(states: var seq[NfaState], src, dst: int, kind: NfaEdgeKind, cs: set[char] = {}) =
  states[src].edges.add(NfaEdge(kind: kind, target: dst, chars: cs))

proc lowerRegex(states: var seq[NfaState], node: RegexNode): NfaFrag =
  case node.kind
  of rnEmpty:
    let s = addState(states)
    let a = addState(states)
    addEdge(states, s, a, nekEps)
    NfaFrag(start: s, accept: a)
  of rnAnchorStart:
    let s = addState(states)
    let a = addState(states)
    addEdge(states, s, a, nekStartAnchor)
    NfaFrag(start: s, accept: a)
  of rnAnchorEnd:
    let s = addState(states)
    let a = addState(states)
    addEdge(states, s, a, nekEndAnchor)
    NfaFrag(start: s, accept: a)
  of rnCharSet:
    let s = addState(states)
    let a = addState(states)
    addEdge(states, s, a, nekChar, node.charSet)
    NfaFrag(start: s, accept: a)
  of rnConcat:
    if node.children.len == 0:
      return lowerRegex(states, RegexNode(kind: rnEmpty))
    var cur = lowerRegex(states, node.children[0])
    for i in 1 ..< node.children.len:
      let nxt = lowerRegex(states, node.children[i])
      addEdge(states, cur.accept, nxt.start, nekEps)
      cur.accept = nxt.accept
    cur
  of rnAlt:
    let s = addState(states)
    let a = addState(states)
    for br in node.children:
      let f = lowerRegex(states, br)
      addEdge(states, s, f.start, nekEps)
      addEdge(states, f.accept, a, nekEps)
    NfaFrag(start: s, accept: a)
  of rnRepeat:
    if node.minCount == 0 and node.maxCount == 0:
      return lowerRegex(states, RegexNode(kind: rnEmpty))
    var hasChain = false
    var chainStart = 0
    var chainAccept = 0
    for _ in 0 ..< node.minCount:
      let f = lowerRegex(states, node.child)
      if not hasChain:
        chainStart = f.start
        chainAccept = f.accept
        hasChain = true
      else:
        addEdge(states, chainAccept, f.start, nekEps)
        chainAccept = f.accept

    if node.maxCount == -1:
      let ls = addState(states)
      let la = addState(states)
      let f = lowerRegex(states, node.child)
      addEdge(states, ls, f.start, nekEps)
      addEdge(states, ls, la, nekEps)
      addEdge(states, f.accept, ls, nekEps)
      if not hasChain:
        chainStart = ls
        chainAccept = la
      else:
        addEdge(states, chainAccept, ls, nekEps)
        chainAccept = la
    else:
      for _ in node.minCount ..< node.maxCount:
        let os = addState(states)
        let oa = addState(states)
        let f = lowerRegex(states, node.child)
        addEdge(states, os, f.start, nekEps)
        addEdge(states, os, oa, nekEps)
        addEdge(states, f.accept, oa, nekEps)
        if not hasChain:
          chainStart = os
          chainAccept = oa
          hasChain = true
        else:
          addEdge(states, chainAccept, os, nekEps)
          chainAccept = oa
    NfaFrag(start: chainStart, accept: chainAccept)

proc compileRegex*(pattern: string): CompiledRegex =
  var parser = RegexParser(pattern: pattern, pos: 0)
  let ast = parseRegexAlt(parser)
  if parser.pos < pattern.len:
    raise newException(ValueError, "Unexpected trailing '" & pattern[parser.pos] & "' in regex: " & pattern)
  var states: seq[NfaState] = @[]
  let frag = lowerRegex(states, ast)
  CompiledRegex(states: states, start: frag.start, accept: frag.accept)

proc epsClosure(states: seq[NfaState], seeds: seq[int], pos, textLen: int): seq[int] =
  var visited = newSeq[bool](states.len)
  var stack: seq[int] = @[]
  for s in seeds:
    if not visited[s]:
      visited[s] = true
      stack.add(s)
      result.add(s)
  while stack.len > 0:
    let cur = stack.pop()
    for e in states[cur].edges:
      let ok =
        case e.kind
        of nekEps: true
        of nekStartAnchor: pos == 0
        of nekEndAnchor: pos == textLen
        of nekChar: false
      if ok and not visited[e.target]:
        visited[e.target] = true
        stack.add(e.target)
        result.add(e.target)

proc regexFullMatch*(pattern, text: string): bool =
  ## Matches the entire `text` against `pattern` using pure-Nim Thompson NFA.
  let nfa = compileRegex(pattern)
  var cur = epsClosure(nfa.states, @[nfa.start], 0, text.len)
  for pos, ch in text:
    var nextSeeds: seq[int] = @[]
    for st in cur:
      for e in nfa.states[st].edges:
        if e.kind == nekChar and ch in e.chars:
          nextSeeds.add(e.target)
    if nextSeeds.len == 0:
      return false
    cur = epsClosure(nfa.states, nextSeeds, pos + 1, text.len)
    if cur.len == 0:
      return false
  nfa.accept in cur

proc regexMatch*(pattern, text: string): bool =
  ## Unanchored regex search honoring `^` and `$` anchors using pure-Nim Thompson NFA.
  let nfa = compileRegex(pattern)
  var cur = epsClosure(nfa.states, @[nfa.start], 0, text.len)
  if nfa.accept in cur:
    return true
  for pos, ch in text:
    var nextSeeds: seq[int] = @[nfa.start]
    for st in cur:
      for e in nfa.states[st].edges:
        if e.kind == nekChar and ch in e.chars:
          nextSeeds.add(e.target)
    cur = epsClosure(nfa.states, nextSeeds, pos + 1, text.len)
    if nfa.accept in cur:
      return true
  false

proc matchesVariablePattern*(pattern, value: string): bool =
  ## Validates a template variable `value` against `pattern`:
  ## uses anchored search when `^` or `$` is present, or full-string match otherwise.
  if pattern.len == 0:
    discard compileRegex(pattern)
    return true
  if '^' in pattern or '$' in pattern:
    regexMatch(pattern, value)
  else:
    regexFullMatch(pattern, value)

# =============================================================================
# 2. Security Validation, SemVer, and Path Hardening
# =============================================================================

proc hasControlOrNul*(s: string): bool =
  ## Returns true if `s` contains NUL (`'\0'`) or any ASCII control char (`< 32` or `127`).
  for ch in s:
    if ord(ch) < 32 or ord(ch) == 127:
      return true
  false

proc hasTraversalSegment*(p: string): bool =
  ## Returns true if any `/`- or `\`-separated path segment is `..`.
  for seg in p.split({'/', '\\'}):
    if seg == "..":
      return true
  false

proc isAbsoluteOrDrivePath*(p: string): bool =
  if p.len == 0:
    return false
  if isAbsolute(p) or p.startsWith("/") or p.startsWith("\\"):
    return true
  if p.len >= 2 and p[0] in {'a'..'z', 'A'..'Z'} and p[1] == ':':
    return true
  false

proc validateProjectName*(name: string) =
  if name.len == 0:
    raise newException(ValueError, "Project name cannot be empty")
  if hasControlOrNul(name):
    raise newException(ValueError, "Project name contains NUL or ASCII control characters")
  if name in [".", ".."] or '/' in name or '\\' in name or hasTraversalSegment(name):
    raise newException(ValueError, "Project name contains invalid path or traversal characters: '" & name & "'")

proc validateTargetArg*(rawTarget: string) =
  if rawTarget.len == 0:
    raise newException(ValueError, "Target project name or path cannot be empty")
  if hasControlOrNul(rawTarget):
    raise newException(ValueError, "Target argument contains NUL or ASCII control characters")
  if hasTraversalSegment(rawTarget):
    raise newException(ValueError, "Path traversal segment '..' is forbidden in target path: '" & rawTarget & "'")

proc validateRelativeTemplatePath*(p: string, contextLabel: string = "template file path") =
  if p.len == 0:
    raise newException(ValueError, contextLabel & " cannot be empty")
  if hasControlOrNul(p):
    raise newException(ValueError, contextLabel & " contains NUL or ASCII control characters")
  if isAbsoluteOrDrivePath(p):
    raise newException(ValueError, contextLabel & " must be relative, got absolute path: '" & p & "'")
  if '\\' in p:
    raise newException(ValueError, contextLabel & " must use '/' separators and no backslashes: '" & p & "'")
  if hasTraversalSegment(p):
    raise newException(ValueError, contextLabel & " contains forbidden '..' traversal segment: '" & p & "'")
  let segs = p.split('/')
  for seg in segs:
    if seg.len == 0 or seg == "." or seg == "..":
      raise newException(ValueError, contextLabel & " contains invalid path segment in '" & p & "'")

proc validateVariableName*(name: string) =
  if name.len == 0:
    raise newException(ValueError, "Template variable name cannot be empty")
  if hasControlOrNul(name):
    raise newException(ValueError, "Template variable name contains NUL or ASCII control characters")
  for idx, ch in name:
    let validFirst = ch in {'a'..'z', 'A'..'Z', '_'}
    let validCont = validFirst or (ch in {'0'..'9'})
    if (idx == 0 and not validFirst) or (idx > 0 and not validCont):
      raise newException(ValueError, "Invalid template variable name '" & name & "'")

proc validateVariableValue*(name, val: string) =
  if hasControlOrNul(val):
    raise newException(ValueError, "Template variable '" & name & "' value contains NUL or ASCII control characters")

proc toProjectSnake*(name: string): string =
  ## Converts a project directory/extension name into a safe snake_case identifier.
  result = ""
  for i, ch in name:
    if ch in {'a'..'z', '0'..'9'}:
      result.add(ch)
    elif ch in {'A'..'Z'}:
      if i > 0 and name[i - 1] in {'a'..'z', '0'..'9'} and (result.len == 0 or result[^1] != '_'):
        result.add('_')
      result.add(toLowerAscii(ch))
    else:
      if result.len > 0 and result[^1] != '_':
        result.add('_')
  result = result.strip(chars = {'_'})
  if result.len == 0:
    result = "pgx_extension"
  elif result[0] in {'0'..'9'}:
    result = "ext_" & result

type
  SemVer = tuple[major, minor, patch: int, pre: string]

proc parseSemVer*(raw: string): SemVer =
  var s = raw.strip()
  if s.len > 0 and s[0] in {'v', 'V'}:
    s = s[1 .. ^1]
  if s.len == 0 or hasControlOrNul(s):
    raise newException(ValueError, "Invalid semantic version: '" & raw & "'")
  let plusIdx = s.find('+')
  if plusIdx >= 0:
    s = s[0 ..< plusIdx]
  var pre = ""
  let dashIdx = s.find('-')
  if dashIdx >= 0:
    pre = s[dashIdx + 1 .. ^1]
    s = s[0 ..< dashIdx]
  let parts = s.split('.')
  if parts.len < 2 or parts.len > 3:
    raise newException(ValueError, "Invalid semantic version (expected major.minor[.patch]): '" & raw & "'")
  for part in parts:
    if part.len == 0:
      raise newException(ValueError, "Invalid empty component in semantic version: '" & raw & "'")
    for ch in part:
      if ch notin DigitChars:
        raise newException(ValueError, "Non-numeric component in semantic version: '" & raw & "'")
  let maj = parseInt(parts[0])
  let min = parseInt(parts[1])
  let pat = if parts.len == 3: parseInt(parts[2]) else: 0
  (major: maj, minor: min, patch: pat, pre: pre)

proc compareSemVer*(a, b: string): int =
  ## Compares two SemVer strings; returns `< 0` if `a < b`, `0` if equal, `> 0` if `a > b`.
  let va = parseSemVer(a)
  let vb = parseSemVer(b)
  if va.major != vb.major: return cmp(va.major, vb.major)
  if va.minor != vb.minor: return cmp(va.minor, vb.minor)
  if va.patch != vb.patch: return cmp(va.patch, vb.patch)
  if va.pre.len == 0 and vb.pre.len > 0: return 1
  if va.pre.len > 0 and vb.pre.len == 0: return -1
  cmp(va.pre, vb.pre)

proc isSubPath(path, root: string): bool =
  let normPath = normalizedPath(path)
  let normRoot = normalizedPath(root).strip(leading = false, trailing = true, chars = {'/', '\\'})
  if normRoot.len == 0:
    return false
  if normPath == normRoot:
    return true
  normPath.startsWith(normRoot & "/") or normPath.startsWith(normRoot & "\\")

proc resolveRealPrefix(path: string): string =
  ## Resolves symlinks on existing components of `path` (up to 16 hops) without failing if leaf does not exist yet.
  let absP = normalizedPath(absolutePath(path))
  when defined(windows):
    return absP
  else:
    var cur = absP
    var tailParts: seq[string] = @[]
    while cur.len > 1 and not dirExists(cur) and not fileExists(cur) and not symlinkExists(cur):
      let sp = splitPath(cur)
      if sp.tail.len > 0:
        tailParts.add(sp.tail)
      if sp.head == cur or sp.head.len == 0:
        break
      cur = sp.head.strip(leading = false, trailing = true, chars = {'/'})
      if cur.len == 0:
        cur = "/"
        break

    var hops = 0
    while hops < 16 and symlinkExists(cur):
      inc hops
      let tgt = expandSymlink(cur)
      cur = if isAbsolute(tgt): normalizedPath(tgt) else: normalizedPath(cur.parentDir / tgt)
    if hops >= 16:
      raise newException(ValueError, "Symlink resolution exceeded maximum depth for: " & path)

    for idx in countdown(tailParts.len - 1, 0):
      cur = cur / tailParts[idx]
    normalizedPath(cur)

proc verifyPathWithinBoundary*(rootDir, relPath: string) =
  ## Walks `relPath` segment-by-segment inside `rootDir`, rejecting any symlink that
  ## contains `..`, uses an absolute target, cycles, or resolves outside `rootDir`.
  validateRelativeTemplatePath(relPath, "path")
  let absRoot = normalizedPath(absolutePath(rootDir))
  when not defined(windows):
    if symlinkExists(absRoot):
      raise newException(ValueError, "Directory root itself cannot be a symlink: " & absRoot)
  let realRoot = resolveRealPrefix(absRoot)

  var cur = absRoot
  for seg in relPath.split('/'):
    cur = cur / seg
    when not defined(windows):
      var checkPath = cur
      var hops = 0
      while symlinkExists(checkPath):
        inc hops
        if hops > 16:
          raise newException(ValueError, "Symlink cycle detected at: " & cur)
        let rawTarget = expandSymlink(checkPath)
        if hasControlOrNul(rawTarget):
          raise newException(ValueError, "Symlink target contains NUL or control characters")
        if hasTraversalSegment(rawTarget):
          raise newException(ValueError, "Symlink target contains forbidden '..' traversal: '" & rawTarget & "'")
        if isAbsoluteOrDrivePath(rawTarget):
          raise newException(ValueError, "Symlink target escapes directory boundary via absolute path: '" & rawTarget & "'")
        let nextTarget = normalizedPath(checkPath.parentDir / rawTarget)
        if not isSubPath(nextTarget, absRoot):
          raise newException(ValueError, "Symlink escapes directory boundary: '" & cur & "' -> '" & rawTarget & "'")
        let realNext = resolveRealPrefix(nextTarget)
        if not isSubPath(realNext, realRoot):
          raise newException(ValueError, "Symlink escapes canonical root boundary: '" & cur & "' -> '" & rawTarget & "'")
        checkPath = nextTarget

# =============================================================================
# 3. Embedded Builtin Templates (`staticRead`) & Manifest Parsing
# =============================================================================

type
  BuiltinTemplateRaw = object
    name: string
    manifestJson: string
    files: seq[tuple[relPath: string, content: string]]

const BuiltinTemplates*: seq[BuiltinTemplateRaw] = @[
  BuiltinTemplateRaw(
    name: "starter-udf",
    manifestJson: staticRead("templates/starter-udf/template.json"),
    files: @[
      ("pgxext.json", staticRead("templates/starter-udf/pgxext.json")),
      ("src/main.nim", staticRead("templates/starter-udf/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("templates/starter-udf/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("templates/starter-udf/regress/expected/01_basic.out")),
      ("README.md", staticRead("templates/starter-udf/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "base-type",
    manifestJson: staticRead("templates/base-type/template.json"),
    files: @[
      ("pgxext.json", staticRead("templates/base-type/pgxext.json")),
      ("src/main.nim", staticRead("templates/base-type/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("templates/base-type/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("templates/base-type/regress/expected/01_basic.out")),
      ("README.md", staticRead("templates/base-type/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "bgworker-service",
    manifestJson: staticRead("templates/bgworker-service/template.json"),
    files: @[
      ("pgxext.json", staticRead("templates/bgworker-service/pgxext.json")),
      ("src/main.nim", staticRead("templates/bgworker-service/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("templates/bgworker-service/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("templates/bgworker-service/regress/expected/01_basic.out")),
      ("README.md", staticRead("templates/bgworker-service/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "hook-observability",
    manifestJson: staticRead("templates/hook-observability/template.json"),
    files: @[
      ("pgxext.json", staticRead("templates/hook-observability/pgxext.json")),
      ("src/main.nim", staticRead("templates/hook-observability/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("templates/hook-observability/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("templates/hook-observability/regress/expected/01_basic.out")),
      ("README.md", staticRead("templates/hook-observability/README.md"))
    ]
  ),
  BuiltinTemplateRaw(
    name: "plugin-custom-type",
    manifestJson: staticRead("templates/plugin-custom-type/template.json"),
    files: @[
      ("pgxext.json", staticRead("templates/plugin-custom-type/pgxext.json")),
      ("src/plugin_type.nim", staticRead("templates/plugin-custom-type/src/plugin_type.nim")),
      ("src/main.nim", staticRead("templates/plugin-custom-type/src/main.nim")),
      ("regress/sql/01_basic.sql", staticRead("templates/plugin-custom-type/regress/sql/01_basic.sql")),
      ("regress/expected/01_basic.out", staticRead("templates/plugin-custom-type/regress/expected/01_basic.out")),
      ("README.md", staticRead("templates/plugin-custom-type/README.md"))
    ]
  )
]

proc parseTemplateManifest*(jsonText: string, sourceLabel: string = "template.json"): TemplateManifest =
  let root = parseJson(jsonText)
  if root.kind != JObject:
    raise newException(ValueError, sourceLabel & ": root must be a JSON object")

  result.name = root.getOrDefault("name").getStr("").strip()
  if result.name.len == 0 or hasControlOrNul(result.name) or '/' in result.name or '\\' in result.name or hasTraversalSegment(result.name):
    raise newException(ValueError, sourceLabel & ": invalid or missing template 'name'")

  result.description = root.getOrDefault("description").getStr("")
  result.minPgxcrownVersion = root.getOrDefault("minPgxcrownVersion").getStr("").strip()
  if result.minPgxcrownVersion.len == 0:
    raise newException(ValueError, sourceLabel & ": missing required 'minPgxcrownVersion'")
  discard parseSemVer(result.minPgxcrownVersion)

  let varsNode = root.getOrDefault("variables")
  if varsNode != nil and varsNode.kind != JNull:
    if varsNode.kind != JArray:
      raise newException(ValueError, sourceLabel & ": 'variables' must be a JSON array")
    var seenVars = initHashSet[string]()
    for vItem in varsNode:
      if vItem.kind != JObject:
        raise newException(ValueError, sourceLabel & ": each entry in 'variables' must be an object")
      let vName = vItem.getOrDefault("name").getStr("").strip()
      validateVariableName(vName)
      if vName in ["project_name", "project_snake", "pgxcrown_version"]:
        raise newException(ValueError, sourceLabel & ": variable name '" & vName & "' is reserved")
      if vName in seenVars:
        raise newException(ValueError, sourceLabel & ": duplicate variable '" & vName & "'")
      seenVars.incl(vName)
      let vDefault = vItem.getOrDefault("default").getStr("")
      validateVariableValue(vName, vDefault)
      let vPattern = vItem.getOrDefault("pattern").getStr("")
      if vPattern.len > 0:
        discard compileRegex(vPattern)
      result.variables.add(TemplateVarDef(
        name: vName,
        defaultVal: vDefault,
        pattern: vPattern
      ))

  let filesNode = root.getOrDefault("files")
  if filesNode.isNil or filesNode.kind != JArray or filesNode.len == 0:
    raise newException(ValueError, sourceLabel & ": 'files' must be a non-empty JSON array")

  for fItem in filesNode:
    var srcRel = ""
    var destRel = ""
    if fItem.kind == JString:
      srcRel = fItem.getStr()
      destRel = srcRel
    elif fItem.kind == JObject:
      srcRel = fItem.getOrDefault("src").getStr("")
      destRel = fItem.getOrDefault("dest").getStr(srcRel)
    else:
      raise newException(ValueError, sourceLabel & ": each entry in 'files' must be a relative path string or {src, dest} object")

    validateRelativeTemplatePath(srcRel, sourceLabel & " source file path")
    if hasControlOrNul(destRel) or isAbsoluteOrDrivePath(destRel) or '\\' in destRel or hasTraversalSegment(destRel):
      raise newException(ValueError, sourceLabel & ": invalid target path '" & destRel & "'")
    if destRel.len == 0:
      raise newException(ValueError, sourceLabel & ": target file path cannot be empty")
    result.files.add(TemplateFileEntry(srcRel: srcRel, destRel: destRel))

proc loadExternalTemplateDir*(dirPath: string): LoadedTemplate =
  if hasControlOrNul(dirPath):
    raise newException(ValueError, "Template directory path contains NUL or control characters")
  let absDir = normalizedPath(absolutePath(dirPath))
  if not dirExists(absDir):
    raise newException(ValueError, "External template directory not found: " & dirPath)
  when not defined(windows):
    if symlinkExists(absDir):
      raise newException(ValueError, "External template directory root cannot be a symlink: " & absDir)
  verifyPathWithinBoundary(absDir, "template.json")
  let manifestPath = absDir / "template.json"
  if not fileExists(manifestPath):
    raise newException(ValueError, "Missing template.json in external template directory: " & absDir)
  let manifest = parseTemplateManifest(readFile(manifestPath), manifestPath)
  for f in manifest.files:
    verifyPathWithinBoundary(absDir, f.srcRel)
    let fullSrc = absDir / f.srcRel
    if not fileExists(fullSrc):
      raise newException(ValueError, "Template file listed in template.json not found: " & fullSrc)
  LoadedTemplate(
    manifest: manifest,
    sourceKind: "external",
    sourceDir: absDir,
    embeddedFiles: initTable[string, string]()
  )

proc loadBuiltinTemplate*(name: string): LoadedTemplate =
  for b in BuiltinTemplates:
    if b.name == name:
      let manifest = parseTemplateManifest(b.manifestJson, "builtin:" & name & "/template.json")
      var fileMap = initTable[string, string]()
      for entry in b.files:
        fileMap[entry.relPath] = entry.content
      for f in manifest.files:
        if f.srcRel notin fileMap:
          raise newException(ValueError, "Builtin template '" & name & "' missing embedded file: " & f.srcRel)
      return LoadedTemplate(
        manifest: manifest,
        sourceKind: "builtin",
        sourceDir: "",
        embeddedFiles: fileMap
      )
  raise newException(ValueError, "Unknown template: '" & name & "'")

proc resolveTemplate*(templateSpec: string, externalTemplatesDir: string = ""): LoadedTemplate =
  ## Resolves a template by explicit directory path, `$PGXTOOL_HOME/templates/<name>`, or builtin name.
  if templateSpec.len == 0:
    raise newException(ValueError, "Template name or path cannot be empty")
  if hasControlOrNul(templateSpec):
    raise newException(ValueError, "Template specification contains NUL or control characters")

  let looksLikePath = templateSpec == "." or '/' in templateSpec or '\\' in templateSpec
  if looksLikePath:
    if hasTraversalSegment(templateSpec):
      raise newException(ValueError, "Template path cannot contain '..' traversal segment: '" & templateSpec & "'")
    return loadExternalTemplateDir(templateSpec)

  if externalTemplatesDir.len > 0:
    let extCand = externalTemplatesDir / templateSpec
    if dirExists(extCand):
      return loadExternalTemplateDir(extCand)

  loadBuiltinTemplate(templateSpec)

proc listAvailableTemplates*(externalTemplatesDir: string = ""): tuple[templates: seq[TemplateSummary], warnings: seq[string]] =
  ## Lists all builtin templates and valid external templates in `externalTemplatesDir`.
  var summaries: seq[TemplateSummary] = @[]
  var warnings: seq[string] = @[]
  var seenExternal = initHashSet[string]()

  if externalTemplatesDir.len > 0 and dirExists(externalTemplatesDir):
    var subdirs: seq[string] = @[]
    for kind, path in walkDir(externalTemplatesDir):
      if kind == pcDir:
        subdirs.add(path)
    subdirs.sort()
    for d in subdirs:
      let manifestFile = d / "template.json"
      if not fileExists(manifestFile):
        continue
      try:
        let loaded = loadExternalTemplateDir(d)
        seenExternal.incl(loaded.manifest.name)
        summaries.add(TemplateSummary(
          name: loaded.manifest.name,
          description: loaded.manifest.description,
          minPgxcrownVersion: loaded.manifest.minPgxcrownVersion,
          sourceKind: "external",
          sourcePath: loaded.sourceDir,
          variables: loaded.manifest.variables
        ))
      except CatchableError as e:
        warnings.add("Skipping invalid external template '" & d & "': " & e.msg)

  for b in BuiltinTemplates:
    if b.name in seenExternal:
      continue
    let loaded = loadBuiltinTemplate(b.name)
    summaries.add(TemplateSummary(
      name: loaded.manifest.name,
      description: loaded.manifest.description,
      minPgxcrownVersion: loaded.manifest.minPgxcrownVersion,
      sourceKind: "builtin",
      sourcePath: "embedded:" & b.name,
      variables: loaded.manifest.variables
    ))

  (templates: summaries, warnings: warnings)

# =============================================================================
# 4. Placeholder Rendering & Project Scaffolding
# =============================================================================

proc renderPlaceholders*(input: string, vars: Table[string, string]): string =
  ## Single-pass `{{key}}` placeholder substitution (immune to double expansion).
  result = newStringOfCap(input.len)
  var i = 0
  while i < input.len:
    if i + 1 < input.len and input[i] == '{' and input[i + 1] == '{':
      let closeIdx = input.find("}}", start = i + 2)
      if closeIdx > i + 2:
        let key = input[i + 2 ..< closeIdx].strip()
        if key in vars:
          result.add(vars[key])
          i = closeIdx + 2
          continue
    result.add(input[i])
    inc i

proc buildTemplateVariables*(
  manifest: TemplateManifest,
  projectName: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string]
): Table[string, string] =
  validateProjectName(projectName)
  if hasControlOrNul(pgxcrownVersion) or pgxcrownVersion.len == 0:
    raise newException(ValueError, "Invalid pgxcrown version string: '" & pgxcrownVersion & "'")

  result = initTable[string, string]()
  result["project_name"] = projectName
  result["project_snake"] = toProjectSnake(projectName)
  result["pgxcrown_version"] = pgxcrownVersion

  for k, v in cliVars:
    validateVariableName(k)
    validateVariableValue(k, v)
    if k in ["project_name", "project_snake", "pgxcrown_version"]:
      raise newException(ValueError, "Cannot override reserved template variable '" & k & "' via --var")

  for vDef in manifest.variables:
    let val = if vDef.name in cliVars: cliVars[vDef.name] else: vDef.defaultVal
    validateVariableValue(vDef.name, val)
    if vDef.pattern.len > 0 and not matchesVariablePattern(vDef.pattern, val):
      raise newException(ValueError,
        "Variable '" & vDef.name & "' value '" & val & "' does not match required pattern '" & vDef.pattern & "'")
    result[vDef.name] = val

  for k, v in cliVars:
    if k notin result:
      result[k] = v

proc scaffoldFromTemplate*(
  templateSpec: string,
  destDir: string,
  pgxcrownVersion: string,
  cliVars: Table[string, string] = initTable[string, string](),
  externalTemplatesDir: string = "",
  rawTargetArg: string = ""
): ScaffoldResult =
  ## Validates manifest, SemVer, variable regexes, paths, and symlinks atomically before writing files.
  if rawTargetArg.len > 0:
    validateTargetArg(rawTargetArg)
  if destDir.len == 0 or hasControlOrNul(destDir):
    raise newException(ValueError, "Invalid destination directory")

  let cleanDest = normalizedPath(absolutePath(destDir)).strip(leading = false, trailing = true, chars = {'/', '\\'})
  if cleanDest.len == 0:
    raise newException(ValueError, "Cannot scaffold at filesystem root")
  when not defined(windows):
    if symlinkExists(cleanDest):
      raise newException(ValueError, "Destination directory cannot be a symlink: " & cleanDest)
  if fileExists(cleanDest):
    raise newException(ValueError, "Destination path already exists as a regular file: " & cleanDest)

  let projectName = cleanDest.lastPathPart
  validateProjectName(projectName)

  let loaded = resolveTemplate(templateSpec, externalTemplatesDir)

  if compareSemVer(pgxcrownVersion, loaded.manifest.minPgxcrownVersion) < 0:
    raise newException(ValueError,
      "Template '" & loaded.manifest.name & "' requires pgxcrown >= " &
      loaded.manifest.minPgxcrownVersion & " (current: " & pgxcrownVersion & ")")

  let vars = buildTemplateVariables(loaded.manifest, projectName, pgxcrownVersion, cliVars)

  type PendingWrite = object
    destRel: string
    destAbs: string
    content: string

  var pending: seq[PendingWrite] = @[]
  var seenDestRels = initHashSet[string]()

  for fEntry in loaded.manifest.files:
    let renderedDestRel = renderPlaceholders(fEntry.destRel, vars)
    validateRelativeTemplatePath(renderedDestRel, "rendered destination path")
    if renderedDestRel in seenDestRels:
      raise newException(ValueError, "Duplicate destination path in template manifest: '" & renderedDestRel & "'")
    seenDestRels.incl(renderedDestRel)

    verifyPathWithinBoundary(cleanDest, renderedDestRel)
    let destAbs = cleanDest / renderedDestRel
    if not isSubPath(destAbs, cleanDest):
      raise newException(ValueError, "Destination path escapes project directory: '" & renderedDestRel & "'")
    if fileExists(destAbs) or dirExists(destAbs):
      raise newException(ValueError, "Refusing to overwrite existing destination path: '" & destAbs & "'")

    let rawContent =
      if loaded.sourceKind == "builtin":
        loaded.embeddedFiles[fEntry.srcRel]
      else:
        verifyPathWithinBoundary(loaded.sourceDir, fEntry.srcRel)
        readFile(loaded.sourceDir / fEntry.srcRel)

    let renderedContent = renderPlaceholders(rawContent, vars)
    pending.add(PendingWrite(
      destRel: renderedDestRel,
      destAbs: destAbs,
      content: renderedContent
    ))

  createDir(cleanDest)
  var written: seq[string] = @[]
  for item in pending:
    createDir(item.destAbs.parentDir)
    writeFile(item.destAbs, item.content)
    written.add(item.destRel)

  ScaffoldResult(
    templateName: loaded.manifest.name,
    sourceKind: loaded.sourceKind,
    destDir: cleanDest,
    projectName: projectName,
    projectSnake: vars["project_snake"],
    writtenFiles: written
  )
