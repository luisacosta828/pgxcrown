# Package

version       = "0.3.0"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
license       = "MIT"

bin           = @["cli/pgxcrown"]
binDir        = "src/bin"

#namedBin["build_extension"] = "pgxcrown"

# Dependencies
requires "nim >= 0.12.0"
