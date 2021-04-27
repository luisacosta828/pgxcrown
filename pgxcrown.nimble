# Package

version       = "0.2.9"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
license       = "MIT"

bin           = @["build_extension"]
binDir        = "src/bin"
# Dependencies
requires "nim >= 0.12.0"
