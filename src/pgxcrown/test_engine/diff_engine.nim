import std/[strutils, os]

const
  ColReset = "\e[0m"
  ColRed = "\e[31m"
  ColGreen = "\e[32m"
  ColYellow = "\e[33m"
  ColCyan = "\e[36m"
  ColBold = "\e[1m"

proc normalizeText*(s: string): string =
  var lines: seq[string]
  for line in s.splitLines():
    lines.add line.strip(leading = false, trailing = true)
  while lines.len > 0 and lines[^1].len == 0:
    discard lines.pop()
  return lines.join("\n")

proc computeSimpleDiff*(expected: string, actual: string): (bool, string) =
  let normExp = normalizeText(expected)
  let normAct = normalizeText(actual)

  if normExp == normAct:
    return (true, "")

  let expLines = normExp.splitLines()
  let actLines = normAct.splitLines()

  var diffReport = ""
  diffReport.add ColCyan & "--- Expected Output (.out)" & ColReset & "\n"
  diffReport.add ColCyan & "+++ Actual PostgreSQL Output" & ColReset & "\n"

  let maxLen = max(expLines.len, actLines.len)
  for i in 0 ..< maxLen:
    let expLine = if i < expLines.len: expLines[i] else: ""
    let actLine = if i < actLines.len: actLines[i] else: ""

    if i >= expLines.len:
      diffReport.add ColGreen & "+ [Line " & $(i + 1) & "] " & actLine & ColReset & "\n"
    elif i >= actLines.len:
      diffReport.add ColRed & "- [Line " & $(i + 1) & "] " & expLine & ColReset & "\n"
    elif expLine != actLine:
      diffReport.add ColYellow & "@@ Line " & $(i + 1) & " @@" & ColReset & "\n"
      diffReport.add ColRed & "- " & expLine & ColReset & "\n"
      diffReport.add ColGreen & "+ " & actLine & ColReset & "\n"

  return (false, diffReport)

proc blessExpectedFile*(expectedFilePath: string, actualContent: string) =
  let norm = normalizeText(actualContent) & "\n"
  createDir(expectedFilePath.parentDir)
  writeFile(expectedFilePath, norm)
