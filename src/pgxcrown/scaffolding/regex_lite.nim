## =============================================================================
## Pure-Nim Thompson NFA Regex Engine (Zero std/re, Zero libpcre)
## =============================================================================
## Supports: ^, $, ., [...], [^...], *, +, ?, {m}, {m,}, {m,n},
##           \d, \D, \w, \W, \s, \S, \., escapes, grouping (...)/(?:...), a|b
## Compatible with static musl builds (`musl-gcc --passL:-static`).
## =============================================================================

import std/strutils

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

  CompiledRegex* = object
    states: seq[NfaState]
    start: int
    accept: int

const
  AllChars = {low(char) .. high(char)}
  AnyExceptNewline = AllChars - {'\n'}
  DigitChars* = {'0'..'9'}
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
