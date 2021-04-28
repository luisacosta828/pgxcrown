# Package

version       = "0.3.3"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
backend       = "c"
license       = "MIT"

bin           = @["pgxcrown/cli/pgxcrown"]
binDir        = "src/bin"
# Dependencies
requires "nim >= 0.12.0"
