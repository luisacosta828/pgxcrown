# Package

version       = "0.9.1"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
backend       = "c"
license       = "MIT"

bin           = @["pgxcrown/pgxtool"]

binDir        = "src/bin"

installExt = @["nim"]

# Dependencies
requires "nim >= 2.0.0"
