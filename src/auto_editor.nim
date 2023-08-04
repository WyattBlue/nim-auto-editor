import std/cmdline
import std/os
import std/osproc
import std/rationals
import std/strformat
import std/tempfiles

import subinfo
import sublevels

let osargs = cmdline.commandLineParams()

if len(osargs) == 0:
  echo """
Auto-Editor is an automatic video/audio creator and editor. By default, it will detect silence and create a new video with those sections cut out.

Run:
    auto-editor --help

To get the list of options."""
  system.quit(1)

case osargs[0]:
  of "info":
    info(osargs)
    system.quit(0)
  of "levels":
    levels(osargs)
    system.quit(0)

let
  myInput = osargs[0]
  dir = createTempDir("tmp", "")
  tempFile = joinPath(dir, "out.wav")

discard execProcess("ffmpeg",
  args = ["-hide_banner", "-y", "-i", myInput, "-map", "0:a:0", "-rf64", "always", tempFile],
  options = {poUsePath}
)

let levels = getAudioThreshold(tempFile, 30//1)

var chunks: seq[(int, int, float)]
var start = 0
for j in 1 .. len(levels) - 1:
  if (levels[j] > 0.04) != (levels[j - 1] > 0.04):
    chunks.add(
      (start, j, (if levels[j - 1] > 0.04: 1.0 else: 0.0))
    )
    start = j
chunks.add((start, len(levels), (if levels[len(levels) - 1] > 0.04: 1.0 else: 0.0)))

echo &"file: {myInput}"
echo &"chunks: {chunks}"

removeDir(dir)
system.quit(0)
