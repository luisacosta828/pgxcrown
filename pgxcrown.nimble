# Package

version       = "0.3.5"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
backend       = "c"
license       = "MIT"

bin           = @["pgxtool"]

binDir        = "src/bin"

installExt = @["nim"]

# Dependencies
requires "nim >= 0.12.0"
