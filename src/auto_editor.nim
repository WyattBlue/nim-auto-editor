import std/[cmdline, tempfiles, os, osproc]
import std/[enumerate, math, rationals, sequtils, strformat]

import ffwrapper
import subinfo
import sublevels
import util
import bar

let osargs = cmdline.commandLineParams()

if len(osargs) == 0:
  echo """
Auto-Editor is an automatic video/audio creator and editor. By default, it will detect silence and create a new video with those sections cut out.

Run:
    auto-editor --help

To get the list of options."""
  quit(1)

case osargs[0]:
  of "info":
    info(osargs)
    quit(0)
  of "levels":
    levels(osargs)
    quit(0)


type
  Exports {.pure.} = enum
    exNormal
    exSS

  Args = object
    input: string = ""
    output: string = ""
    `export`: Exports = exNormal
    noOpen: bool = false

proc vanparse(osargs: seq[string]): Args =
  var i = 0
  var arg: string
  var args = Args()

  while i < len(osargs):
    arg = osargs[i]

    if arg == "--export":
      if osargs[i + 1] == "normal":
        args.`export` = exNormal
      elif osargs[i + 1] == "ss":
        args.`export` = exSS
      else:
        echo &"Invalid `--export` value: {osargs[i + 1]}"
        quit(1)
      i += 1
    elif arg == "-o" or arg == "--output":
      args.output = osargs[i + 1]
      i += 1
    elif arg == "--no-open":
      args.noOpen = true
    elif args.input == "":
      args.input = arg
    else:
      echo &"Invalid option: {arg}"
      quit(1)
    i += 1

  if args.input == "":
    echo "Input required"
    quit(1)

  if args.output == "":
    let spl = splitFile(args.input)
    args.output = joinPath(spl.dir, spl.name & "_ALTERED" & spl.ext)

  return args


let
  args = vanparse(osargs)
  dir = createTempDir("tmp", "")
  tempFile = dir.joinPath("out.wav")
  log = initLog(dir)
  fileInfo = initFileInfo("ffprobe", args.input, log)

if fileExists(args.output):
  removeFile(args.output)

if len(fileInfo.a) == 0:
  log.error("Needs at least one audio stream")

discard execProcess("ffmpeg",
  args = ["-hide_banner", "-y", "-i", args.input, "-map", "0:a:0", "-rf64",
      "always", tempFile],
  options = {poUsePath}
)

let tb = (if len(fileInfo.v) > 0: fileInfo.v[0].fps else: 30//1)
let levels = getAudioThreshold(tempFile, tb, log)

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
    if hasLoud[j - 1]:
      chunks.add((start, j, 1.0))
    start = j

if hasLoud[^1]:
  chunks.add((start, len(hasLoud), 1.0))

func toTimecode(v: int, tb: Rational[int]): string =
  let fSecs = toFloat(v / tb)
  let iSecs = toInt(fSecs)
  var hours: int
  var (minutes, secs) = divmod(iSecs, 60)
  (hours, minutes) = divmod(minutes, 60)
  let realSecs = toFloat(secs) + (fSecs - toFloat(iSecs))

  return &"{hours:02d}:{minutes:02d}:{realSecs:06.3f}"

func toSec(v: int, tb: Rational[int]): string =
  let fSecs = toFloat(v / tb)
  return &"{fSecs:.3f}"


case args.`export`:
  of exSS:
    let concatFile = dir.joinPath("concat.txt")
    let f = open(concatFile, fmWrite)
    for i, chunk in enumerate(chunks):
      let hmm = dir.joinPath(&"{i}.mp4")
      f.writeLine(&"file '{hmm}'")

    f.close()
    let bar = initBar(chunks.len)
    for i, chunk in enumerate(chunks):
      bar.tick(i+1)
      discard execProcess("ffmpeg",
        args = [
        "-hide_banner", "-y", "-i", args.input,
        "-ss", toTimecode(chunk[0], tb), "-to", toTimecode(chunk[1], tb), dir.joinPath(&"{i}.mp4")
        ],
        options = {poUsePath}
      )

    discard execProcess("ffmpeg",
      args = ["-hide_banner", "-y", "-f", "concat", "-safe", "0", "-i", concatFile, args.output],
      options = {poUsePath}
    )
  of exNormal:
    var select = ""

    for i, chunk in enumerate(chunks):
      select &= &"between(t,{toSec(chunk[0],tb)},{toSec(chunk[1],tb)})"

      if i != len(chunks) - 1:
        select &= "+"

    discard execProcess("ffmpeg",
      args = ["-hide_banner", "-y", "-i", args.input,
        "-vf", &"select='{select}',setpts=N/FRAME_RATE/TB",
        "-af", &"aselect='{select}',asetpts=N/SR/TB", args.output],
      options = {poUsePath}
    )

if not args.noOpen:
  discard execProcess("open", args=[args.output], options={poUsePath})
log.endProgram()
