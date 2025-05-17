# Package
version       = "0.1.0"
author        = "WyattBlue"
description   = "Auto-Editor: Efficient media analysis and rendering"
license       = "Unlicense"
srcDir        = "src"
bin           = @["auto-editor"]

# Dependencies
requires "nim >= 2.2.2"

# Tasks
task build, "Build the project in debug mode":
  exec "nim c -d:debug --out:auto-editor src/main.nim"

task make, "Export the project":
  exec "nim c -d:danger --passL:-s --out:auto-editor src/main.nim"
