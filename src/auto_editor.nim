import std/cmdline
import std/os
import std/osproc
import std/rationals
import std/strformat
import std/tempfiles
import std/enumerate
import std/sequtils

import subinfo
import sublevels
import util

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
  log = initLog(dir)

discard execProcess("ffmpeg",
  args = ["-hide_banner", "-y", "-i", myInput, "-map", "0:a:0", "-rf64",
      "always", tempFile],
  options = {poUsePath}
)

let levels = getAudioThreshold(tempFile, 30//1, log)

var hasLoud: seq[bool] = @[]
for j in levels:
  hasLoud.add(j >= 0.04)

proc removeSmall(arr: var seq[bool], lim: int, replace, `with`: bool) =
  var startP = 0
  var active = false
  for j, item in enumerate(arr):
    if item == replace:
      if not active:
        startP = j
        active = true

      if j == len(arr) - 1 and j - startP < lim:
        for i in startP ..< len(arr):
          arr[i] = `with`
    elif active:
      if j - startP < lim:
        for i in startP ..< j:
          arr[i] = `with`
      active = false

# Apply minclip of 3
removeSmall(hasLoud, 3, true, false)

# Apply mincut of 6
removeSmall(hasLoud, 6, false, true)

# Apply margin of 0.2s 0.2s
proc mutMargin(arr: var seq[bool], startM, endM: int) =
  var startIndex, endIndex: seq[int]
  let arrLen = len(arr)

  for j in 1 ..< arrLen:
    if arr[j] != arr[j - 1]:
      if arr[j]:
        startIndex.add(j)
      else:
        endIndex.add(j)

  if startM > 0:
    for i in startIndex:
      let index = max(i - startM, 0) ..< i
      arr[index] = repeat(true, index.len)
  elif startM < 0:
    for i in startIndex:
      let index = i ..< min(i - startM, arrLen)
      arr[index] = repeat(false, index.len)

  if endM > 0:
    for i in endIndex:
      let index = i ..< min(i + endM, arrLen)
      arr[index] = repeat(true, index.len)
  elif endM < 0:
    for i in endIndex:
      let index = max(i + endM, 0) ..< i
      arr[index] = repeat(false, index.len)

mutMargin(hasLoud, 6, 6)


var chunks: seq[(int, int, float)]
var start = 0
for j in 1 ..< len(hasLoud):
  if hasLoud[j] != hasLoud[j - 1]:
    chunks.add(
      (start, j, (if hasLoud[j - 1]: 1.0 else: 0.0))
    )
    start = j

chunks.add(
  (start, len(hasLoud), (if hasLoud[^1]: 1.0 else: 0.0))
)

echo &"chunks: {chunks}"

log.endProgram()
