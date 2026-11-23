import unittest
import std/[os, strutils]
import ../src/pgxcrown/lsp_config

suite "Pgxcrown - LSP Config & nim.cfg Generation Suite":

  test "renderProjectNimCfg emits expected managed block without link/lib flags":
    let rendered = renderProjectNimCfg(
      pgxcrownSrcDir = "/opt/pgxcrown/src",
      pgIncServer = "/usr/include/postgresql/18/server",
      pgIncBase = "/usr/include/postgresql",
      pgVersion = 18
    )
    check rendered.startsWith(ManagedBeginMarker & "\n")
    check rendered.endsWith(ManagedEndMarker & "\n")
    check """--path:"/opt/pgxcrown/src"""" in rendered
    check """--path:"src"""" in rendered
    check """--path:"private"""" in rendered
    check "--mm:arc" in rendered
    check "-d:pgTargetVersion=18" in rendered
    check """--cincludes:"/usr/include/postgresql/18/server"""" in rendered
    check """--cincludes:"/usr/include/postgresql"""" in rendered
    check "--app:lib" notin rendered
    check "--passL" notin rendered
    check "--wrap=malloc" notin rendered
    check "--compileOnly" notin rendered

  test "renderProjectNimCfg omits empty paths, duplicate cincludes, and zero pgVersion":
    let rendered = renderProjectNimCfg(
      pgxcrownSrcDir = "",
      pgIncServer = "/usr/include/postgresql",
      pgIncBase = "/usr/include/postgresql",
      pgVersion = 0
    )
    check """--path:""""" notin rendered
    check """--path:"src"""" in rendered
    check """--path:"private"""" in rendered
    check "--mm:arc" in rendered
    check "-d:pgTargetVersion" notin rendered
    check rendered.count("--cincludes:") == 1

    let noIncludes = renderProjectNimCfg("/repo/src", "", "", 16)
    check "--cincludes:" notin noIncludes
    check "-d:pgTargetVersion=16" in noIncludes

  test "renderProjectNimCfg escapes spaces, quotes, and backslashes":
    let rendered = renderProjectNimCfg(
      pgxcrownSrcDir = """C:\Users\Dev User\pgx"crown\src""",
      pgIncServer = """/opt/pg 18/inc"srv""",
      pgIncBase = "",
      pgVersion = 18
    )
    check """--path:"C:\\Users\\Dev User\\pgx\"crown\\src"""" in rendered
    check """--cincludes:"/opt/pg 18/inc\"srv"""" in rendered

  test "mergeNimCfgContent creates managed block when existing content is empty":
    let managed = renderProjectNimCfg("/repo/src", "/inc/srv", "/inc/base", 18)
    check mergeNimCfgContent("", managed) == managed
    check mergeNimCfgContent("   \n\n", managed) == managed

  test "mergeNimCfgContent appends managed block and preserves user lines idempotently":
    let existing = "--hints:off\n-d:myCustomDefine=42\n"
    let managed = renderProjectNimCfg("/repo/src", "/inc/srv", "/inc/base", 16)
    let firstMerge = mergeNimCfgContent(existing, managed)
    check firstMerge.startsWith("--hints:off\n-d:myCustomDefine=42\n\n# BEGIN PGXCROWN MANAGED\n")
    check firstMerge.endsWith("# END PGXCROWN MANAGED\n")
    let secondMerge = mergeNimCfgContent(firstMerge, managed)
    check secondMerge == firstMerge

  test "mergeNimCfgContent replaces only managed block preserving lines before and after":
    let oldManaged = renderProjectNimCfg("/old/src", "/old/srv", "/old/base", 14)
    let existing = "# Top user comment\n--verbosity:1\n\n" & oldManaged & "\n# Bottom user comment\n-d:release\n"
    let newManaged = renderProjectNimCfg("/new/src", "/new/srv", "/new/base", 18)

    let merged = mergeNimCfgContent(existing, newManaged)
    check "# Top user comment\n--verbosity:1\n" in merged
    check "\n# Bottom user comment\n-d:release\n" in merged
    check "/old/src" notin merged
    check "/old/srv" notin merged
    check "-d:pgTargetVersion=14" notin merged
    check "/new/src" in merged
    check "/new/srv" in merged
    check "-d:pgTargetVersion=18" in merged
    check merged.count(ManagedBeginMarker) == 1
    check merged.count(ManagedEndMarker) == 1
    check mergeNimCfgContent(merged, newManaged) == merged

  test "mergeNimCfgContent handles CRLF and unterminated begin marker cleanly":
    let existing = "--hints:off\r\n# BEGIN PGXCROWN MANAGED\r\n--path:\"/stale\"\r\n"
    let managed = renderProjectNimCfg("/fresh/src", "", "", 17)
    let merged = mergeNimCfgContent(existing, managed)
    check "\r" notin merged
    check "--hints:off\n" in merged
    check "/stale" notin merged
    check "/fresh/src" in merged
    check merged.count(ManagedBeginMarker) == 1
    check merged.count(ManagedEndMarker) == 1

  test "writeProjectNimCfg and syncProjectNimCfg persist and preserve user lines on disk":
    let tmpDir = getTempDir() / ("pgx_lsp_test_" & $getCurrentProcessId())
    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir / "src")
    defer:
      if dirExists(tmpDir):
        removeDir(tmpDir)

    let cfgPath = writeProjectNimCfg(tmpDir, "/pgx/src", "/pg/inc/server", "/pg/inc", 15)
    check cfgPath == tmpDir / "nim.cfg"
    check fileExists(cfgPath)

    # Simulate user adding lines before and after managed section
    let current = readFile(cfgPath)
    writeFile(cfgPath, "# User header\n" & current & "# User footer\n")

    discard writeProjectNimCfg(tmpDir, "/pgx/src_v2", "/pg/inc/18/server", "/pg/inc", 18)
    let updated = readFile(cfgPath)
    check updated.startsWith("# User header\n")
    check updated.endsWith("# User footer\n")
    check "/pgx/src_v2" in updated
    check "-d:pgTargetVersion=18" in updated
    check "-d:pgTargetVersion=15" notin updated

    # syncProjectNimCfg discovers repo pgxcrown src and PG env cleanly while still preserving user lines
    let synced = syncProjectNimCfg(tmpDir, pgVersionOverride = 17)
    check synced.cfgPath == cfgPath
    check synced.pgVersion == 17
    check synced.pgxcrownSrcDir.len > 0
    check fileExists(synced.pgxcrownSrcDir / "pgxcrown.nim")
    let afterSync = readFile(cfgPath)
    check afterSync.startsWith("# User header\n")
    check afterSync.endsWith("# User footer\n")
    check "-d:pgTargetVersion=17" in afterSync

  test "parsePgMajorVersion and parsePgTargetVersion handle standard version strings":
    check parsePgMajorVersion("PostgreSQL 14.20 (Ubuntu 14.20-0ubuntu0.22.04.1)") == 14
    check parsePgMajorVersion("PostgreSQL 18.7 (Debian 18.7-1.pgdg13+5)") == 18
    check parsePgMajorVersion("PostgreSQL 17beta1") == 17
    check parsePgMajorVersion("PostgreSQL 16rc1") == 16
    check parsePgMajorVersion("") == 0
    check parsePgMajorVersion("not a version") == 0

    check parsePgTargetVersion("14") == 14
    check parsePgTargetVersion("18") == 18
    check parsePgTargetVersion("latest") == 18
    check parsePgTargetVersion(" LATEST ") == 18
    check parsePgTargetVersion("13") == -1
    check parsePgTargetVersion("abc") == -1
