import os
import std/strformat

from subinfo import info
from sublevels import levels

let osargs = os.commandLineParams()

if len(osargs) == 0:
  echo """
Auto-Editor is an automatic video/audio creator and editor. By default, it will detect silence and create a new video with those sections cut out.

Run:
    auto-editor --help

To get the list of options."""
  system.quit(1)

if osargs[0] == "info":
  info(osargs)
  system.quit(0)

if osargs[0] == "levels":
  levels(osargs)
  system.quit(0)

stderr.writeLine(&"Unknown subcommand: {osargs[0]}")
system.quit(1)
