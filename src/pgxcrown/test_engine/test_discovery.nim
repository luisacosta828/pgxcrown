import std/[os, algorithm, strutils]

type
  TestCase* = object
    name*: string
    sqlPath*: string
    expectedPath*: string

proc discoverTests*(projectDir: string): seq[TestCase] =
  let sqlDir = projectDir / "tests" / "sql"
  let expectedDir = projectDir / "tests" / "expected"

  if not dirExists(sqlDir):
    return @[]

  var files: seq[string]
  for kind, path in walkDir(sqlDir):
    if kind == pcFile and path.endsWith(".sql"):
      files.add path

  files.sort()

  for f in files:
    let (dir, name, ext) = splitFile(f)
    let expFile = expectedDir / (name & ".out")
    result.add TestCase(
      name: name,
      sqlPath: f,
      expectedPath: expFile
    )
