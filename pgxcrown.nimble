# Package

version       = "0.2.3"
author        = "luisacosta828"
description   = "Build Postgres extensions in Nim."
srcDir        = "src"
license       = "MIT"

# Dependencies
bin = @["pgx"]
installExt = @["nim"]
requires "nim >= 0.12.0"