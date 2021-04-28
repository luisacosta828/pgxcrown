# Package

version       = "0.3.2"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
#srcDir        = "src"
license       = "MIT"

bin           = @["src/cli/pgxcrown"]
binDir        = "src/bin"

# Dependencies
requires "nim >= 0.12.0"
