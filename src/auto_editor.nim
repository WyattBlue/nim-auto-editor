import os
import std/strformat
import osproc

from subinfo import info
from sublevels import levels
from wavfile import WavContainer, read

let osargs = os.commandLineParams()

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

let myInput = osargs[0]

const tempFile = "out.wav"

discard execProcess("ffmpeg",
  args = ["-hide_banner", "-y", "-i", myInput, "-map", "0:a:0", "-rf64", "always", tempFile],
  options = {poUsePath}
)

let con = read(tempFile)
echo &"sr: {con}"

echo &"file: {myInput}"
system.quit(0)
