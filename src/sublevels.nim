import os
import osproc
import strutils
import std/memfiles
import std/tempfiles
import std/strformat
import std/rationals

import wavfile

type
  Args = object
    myInput: string
    ffLoc: string
    timeBase: Rational[int]
    stream: int

proc error(msg: string) =
  stderr.writeLine(&"Error! {msg}")
  system.quit(1)

func parseRational(val: string): Rational[int] =
  let hmm = val.split("/", 1)

  if len(hmm) == 1:
    try:
      return parseInt(hmm[0]) // 1
    except CatchableError:
      return 0//1

  try:
    let
      num = parseInt(hmm[0])
      den = parseInt(hmm[1])
    return num // den
  except CatchableError:
    return 0//1

proc vanparse(args: seq[string]): Args =
  var
    myArgs = Args(myInput: "", ffLoc: "ffmpeg", timeBase: 0//1, stream: 0)
    arg: string
    i = 1

  if len(args) == 0:
    echo "Display loudness over time"
    system.quit(1)

  while i < len(args):
    arg = args[i]

    if arg == "--help" or arg == "-h":
      echo """Usage: [file ...] [options]

Options:
  --edit METHOD:[ATTRS?]            Select the kind of detection to analyze
                                    with attributes
  -tb, --timebase NUM               Set custom timebase
  --ffmpeg-location                 Point to your custom ffmpeg file
  -h, --help                        Show info about this program then exit
"""
      system.quit(1)

    elif arg == "--ffmpeg-location":
      myArgs.ffLoc = args[i+1]
      i += 1
    elif arg == "--edit":
      if not args[i+1].startswith("audio:"):
        error("`--edit` only supports audio method")

      myArgs.stream = parseInt(args[i+1][6 .. ^1])
      i += 1
    elif arg == "--timebase" or arg == "-tb":
      myArgs.timeBase = parseRational(args[i+1])
      if myArgs.timeBase == 0//1:
        error("Invalid timebase")
      i += 1
    elif myArgs.myInput != "":
      error("Only one file allowed")
    else:
      myArgs.myInput = arg

    i += 1

  if myArgs.myInput == "":
    error("Input file required")
  if myArgs.timeBase == 0//1:
    error("timebase must be set!")
  return myArgs


proc levels(osargs: seq[string]) =
  let
    args = vanparse(osargs)
    myInput = args.myInput
    timeBase = args.timeBase
    dir = createTempDir("tmp", "")
    temp_file = joinPath(dir, "out.wav")


  discard execProcess(args.ffLoc,
    args = ["-hide_banner", "-y", "-i", myInput, "-map", &"0:a:{args.stream}",
        "-rf64", "always", temp_file],
    options = {poUsePath}
  )

  var
    wav: WavContainer = read(temp_file)
    mm = memfiles.open(temp_file, mode = fmRead)
    thres: seq[float64] = @[]

  let samp_per_ticks = uint64((int(wav.sr) / timeBase * int(
      wav.channels)).toInt())

  if wav.bytes_per_sample != 2:
    raise newException(IOError, "Expects int16 only")

  var
    samp: int16
    max_volume: int16 = 0
    local_max: int16 = 0
    local_maxs: seq[int16] = @[]

  for i in wav.start ..< wav.start + wav.size:
    # https://forum.nim-lang.org/t/2132
    samp = cast[ptr int16](cast[uint64](mm.mem) + wav.bytes_per_sample * i)[]

    if samp > max_volume:
      max_volume = samp
    elif samp == low(int16):
      max_volume = high(int16)
    elif -samp > max_volume:
      max_volume = -samp

    if samp > local_max:
      local_max = samp
    elif samp == low(int16):
      local_max = high(int16)
    elif -samp > local_max:
      local_max = -samp

    if i != wav.start and (i - wav.start) mod samp_per_ticks == 0:
      local_maxs.add(local_max)
      local_max = 0

  if unlikely(max_volume == 0):
    for _ in local_maxs:
      thres.add(0)
  else:
    for lo in local_maxs:
      thres.add(lo / max_volume)

  if defined(windows):
    var i = 0
    var buf = "\r\n@start\r\n"
    for t in thres:
      buf &= &"{t:.20f}\r\n"
      i += 1
      if i > 4000:
        stdout.writeLine(buf)
        stdout.flushFile()
        buf = ""
        i = 0

    stdout.writeLine(buf)
    stdout.flushFile()
  else:
    echo "\n@start"
    for t in thres:
      echo &"{t:.20f}"
    echo ""

  mm.close()
  removeDir(dir)

export levels
