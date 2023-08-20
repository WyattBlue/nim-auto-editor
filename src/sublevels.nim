import std/[memfiles, tempfiles, os, osproc]
import std/[rationals, strformat, strutils]

import util
import wavfile

type
  Args = object
    myInput: string
    ffLoc: string
    timeBase: Rational[int]
    stream: int

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
    log = Log()
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
        log.error("`--edit` only supports audio method")

      myArgs.stream = parseInt(args[i+1][6 .. ^1])
      i += 1
    elif arg == "--timebase" or arg == "-tb":
      myArgs.timeBase = parseRational(args[i+1])
      if myArgs.timeBase == 0//1:
        log.error("Invalid timebase")
      i += 1
    elif myArgs.myInput != "":
      log.error("Only one file allowed")
    else:
      myArgs.myInput = arg

    i += 1

  if myArgs.myInput == "":
    log.error("Input file required")
  if myArgs.timeBase == 0//1:
    log.error("timebase must be set!")
  return myArgs


proc getAudioThreshold(tempFile: string, timeBase: Rational[int],
    log: Log): seq[float64] =
  var
    wav: WavContainer = read(tempFile, log)
    mm = memfiles.open(tempFile, mode = fmRead)
    thres: seq[float64] = @[]

  let samp_per_ticks = uint64((int(wav.sr) / timeBase * int(
      wav.channels)).toInt())

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

  mm.close()
  return thres


proc levels(osargs: seq[string]) =
  let
    args = vanparse(osargs)
    dir = createTempDir("tmp", "")
    tempFile = joinPath(dir, "out.wav")
    log = initLog(dir)

  discard execProcess(args.ffLoc,
    args = ["-hide_banner", "-y", "-i", args.myInput, "-map",
        &"0:a:{args.stream}", "-rf64", "always", tempFile],
    options = {poUsePath}
  )

  var i = 0
  var buf = "\n@start\n"
  for t in getAudioThreshold(tempFile, args.timeBase, log):
    buf &= &"{t:.20f}\n"
    i += 1
    if i > 4000:
      stdout.write(buf)
      stdout.flushFile()
      buf = ""
      i = 0

  buf &= "\n"
  stdout.write(buf)
  stdout.flushFile()

  removeDir(dir)

export levels, getAudioThreshold
