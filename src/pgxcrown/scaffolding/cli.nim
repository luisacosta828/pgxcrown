## =============================================================================
## Pgxcrown Scaffolding CLI Subsystem (`list-templates` & `new`)
## =============================================================================
## CLI-only subcommand parsing and execution invoked by `pgxtool.nim`.
## Never imported by extension library runtime modules (`pgxcrown.nim` / `pgx.nim`).
## =============================================================================

import std/[json, os, strutils, tables]
import ./manifest
import ./registry
import ./renderer

proc new_cli_helper*() =
  echo """
Usage: pgxtool new <name|path> [options]

Scaffold a new pgxcrown extension project from a builtin or external template.
Works anywhere (including '.' or './my_ext') without requiring 'pgxtool init'.
Automatically generates an IDE/LSP-ready nim.cfg in the created project.

Arguments:
  <name|path>             Project name or target directory path (e.g. my_ext, ./my_ext, .)

Options:
  --template, -t <spec>   Template name (builtin or in $PGXTOOL_HOME/templates) or directory path
                          (default: starter-udf)
  --var <key=val>         Template variable override (repeatable)
  --help, -h              Display this help message

Examples:
  * pgxtool new ./my_ext --template starter-udf
  * pgxtool new . --template base-type --var type_name=email_tag
  * pgxtool new my_plugin --template plugin-custom-type
  * pgxtool new my_svc --template secure-service --var guc_prefix=my_svc
"""

proc runListTemplatesCmd*(pgxtoolInitDir, pgxcrownVersion: string) =
  let extTplDir = pgxtoolInitDir / "templates"
  let (templates, warnings) = listAvailableTemplates(extTplDir)
  for w in warnings:
    echo "⚠️  ", w
  echo "Available pgxcrown templates (pgxcrown v", pgxcrownVersion, "):"
  for tpl in templates:
    let srcTag = if tpl.sourceKind == "builtin": "builtin" else: "external: " & tpl.sourcePath
    echo "  * ", tpl.name, "  [", srcTag, "] (min pgxcrown >= ", tpl.minPgxcrownVersion, ")"
    if tpl.description.len > 0:
      echo "      ", tpl.description
    if tpl.variables.len > 0:
      var varList: seq[string] = @[]
      for v in tpl.variables:
        varList.add(v.name & "=" & v.defaultVal)
      echo "      vars: ", varList.join(", ")

proc runNewProjectCmd*(pgxtoolInitDir, pgxcrownVersion: string) =
  let pc = paramCount()
  if pc == 1:
    new_cli_helper()
    return

  var targetArg = ""
  var templateSpec = "starter-udf"
  var cliVars = initTable[string, string]()
  var idx = 2
  while idx <= pc:
    let flag = paramStr(idx)
    if flag in ["--help", "-h", "help"]:
      new_cli_helper()
      return
    elif flag in ["--template", "-t"]:
      if idx + 1 > pc:
        quit("❌ Missing value after '" & flag & "'. Run 'pgxtool new --help' for usage.")
      templateSpec = paramStr(idx + 1)
      idx += 2
    elif flag.startsWith("--template="):
      templateSpec = flag[11..^1]
      idx += 1
    elif flag == "--var":
      if idx + 1 > pc:
        quit("❌ Missing key=value after '--var'. Example: --var type_name=short_code")
      let kv = paramStr(idx + 1)
      if '=' notin kv:
        quit("❌ Invalid '--var' format '" & kv & "' (expected key=val)")
      let parts = kv.split('=', maxsplit = 1)
      cliVars[parts[0]] = parts[1]
      idx += 2
    elif flag.startsWith("--var="):
      let kv = flag[6..^1]
      if '=' notin kv:
        quit("❌ Invalid '--var' format '" & kv & "' (expected key=val)")
      let parts = kv.split('=', maxsplit = 1)
      cliVars[parts[0]] = parts[1]
      idx += 1
    elif flag.startsWith("-"):
      quit("❌ Unknown option for 'pgxtool new': " & flag)
    elif targetArg.len == 0:
      targetArg = flag
      idx += 1
    else:
      quit("❌ Unexpected argument for 'pgxtool new': " & flag)

  if targetArg.len == 0:
    quit("❌ Missing project name or target path. Run 'pgxtool new --help' for usage.")

  let pgxtoolConfig = pgxtoolInitDir / "config.json"
  try:
    validateTargetArg(targetArg)
    let isExplicitPath = targetArg == "." or '/' in targetArg or '\\' in targetArg
    var destDir = ""
    var registerInConfig = false
    if isExplicitPath:
      destDir = absolutePath(targetArg)
    elif fileExists(pgxtoolConfig):
      destDir = pgxtoolInitDir / targetArg
      registerInConfig = true
    else:
      destDir = getCurrentDir() / targetArg

    let res = scaffoldFromTemplate(
      templateSpec = templateSpec,
      destDir = destDir,
      pgxcrownVersion = pgxcrownVersion,
      cliVars = cliVars,
      externalTemplatesDir = pgxtoolInitDir / "templates",
      rawTargetArg = targetArg
    )
    if registerInConfig:
      try:
        var cfg = parseJson(readFile(pgxtoolConfig))
        if cfg.kind == JObject:
          if not cfg.hasKey("modules") or cfg["modules"].kind != JObject:
            cfg["modules"] = newJObject()
          cfg["modules"][res.projectName] = %*{"test": {}}
          writeFile(pgxtoolConfig, pretty(cfg))
      except CatchableError:
        discard

    echo "✅ Created extension '", res.projectName, "' from template '", res.templateName, "' (", res.sourceKind, ")"
    echo "   Directory: ", res.destDir
    echo "   Files:     ", res.writtenFiles.len
    echo "   Next:      pgxtool build-extension ", quoteShell(res.destDir)
    echo "              pgxtool test ", quoteShell(res.destDir)
  except CatchableError as e:
    quit("❌ " & e.msg)
