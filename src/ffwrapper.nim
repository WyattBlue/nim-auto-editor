import std/osproc
import std/strutils except parseFloat
import std/strformat
import std/rationals

from std/parseutils import parseFloat

type
  StreamKind = enum
    VideoKind,
    AudioKind,
    SubtitleKind,
    ContainerKind,
    DataKind,

  Stream* = ref object
    duration*: float = 0.0
    bitrate*: uint64 = 0
    codec*: string
    lang*: string
    case kind*: StreamKind
    of VideoKind:
      width*: uint64
      height*: uint64
      fps*: string
      timebase*: string
      dar*: Rational[int]
      sar*: Rational[int]
      pix_fmt*: string
      color_range*: string
      color_space*: string
      color_transfer*: string
      color_primaries*: string
    of AudioKind:
      sampleRate*: uint64
      channels*: uint64
    of SubtitleKind:
      discard
    of ContainerKind:
      discard
    of DataKind:
      discard

func parseRational(val: string): Rational[int] =
  let hmm = val.split(":")

  if len(hmm) != 2:
    return 0//1

  try:
    let
      num = parseInt(hmm[0])
      den = parseInt(hmm[1])
    return num // den
  except CatchableError:
    return 0//1

proc error(msg: string) =
  stderr.writeLine(&"Error! {msg}")
  system.quit(1)

proc getAllStreams(ffLoc: string, input: string): seq[Stream] =
  var ffout: string
  try:
    ffout = execProcess(ffLoc,
      args = ["-v", "-8", "-show_streams", "-show_format", input],
      options = {poUsePath}
    )
  except OSError:
    error(&"Invalid ffprobe location: {ffLoc}")
  var
    foo: seq[string]
    key: string
    val: string
    codec: string
    allStreams: seq[Stream]

  for line in splitLines(ffout):
    if line == "" or line.startswith("[/"):
      continue

    if line.startswith("["):
      if line == "[FORMAT]":
        allStreams.add(Stream(kind: ContainerKind))
      continue

    if line.startswith("TAG:language="):
      key = "lang"
      val = line[13 .. ^1]
    elif line.startswith("TAG:"):
      continue

    if not line.startswith("TAG:"):
      foo = line.split("=")
      if len(foo) != 2:
        continue

      key = foo[0]
      val = foo[1]

    if key == "codec_name":
      codec = val

    if key == "codec_type":
      if val == "video":
        allStreams.add(
          Stream(kind: VideoKind, codec: codec, lang: "", dar: 0//1, sar: 1//1,
              color_transfer: "unknown")
        )
      elif val == "audio":
        allStreams.add(Stream(kind: AudioKind, codec: codec, lang: ""))
      elif val == "subtitle":
        allStreams.add(Stream(kind: SubtitleKind, codec: codec, lang: ""))
      else:
        allStreams.add(Stream(kind: DataKind, codec: codec))

    if len(allStreams) > 0:
      if key == "bit_rate" and val != "N/A":
        allStreams[^1].bitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, allStreams[^1].duration, 0)
      if key == "lang":
        allStreams[^1].lang = val

      if allStreams[^1].kind == VideoKind:
        if key == "width":
          allStreams[^1].width = parseUInt(val)
        if key == "height":
          allStreams[^1].height = parseUInt(val)
        if key == "avg_frame_rate":
          allStreams[^1].fps = val
        if key == "sample_aspect_ratio" and val != "N/A":
          allStreams[^1].sar = parseRational(val)
        if key == "display_aspect_ratio" and val != "N/A":
          allStreams[^1].dar = parseRational(val)
        if key == "time_base":
          allStreams[^1].timebase = val

        if key == "pix_fmt":
          allStreams[^1].pix_fmt = val
        if key == "color_range":
          allStreams[^1].color_range = val
        if key == "color_space":
          allStreams[^1].color_space = val
        if key == "color_transfer":
          allStreams[^1].color_transfer = val
        if key == "color_primaries":
          allStreams[^1].color_primaries = val

      if allStreams[^1].kind == AudioKind:
        if key == "sample_rate":
          allStreams[^1].sampleRate = parseUInt(val)
        if key == "channels":
          allStreams[^1].channels = parseUInt(val)

  if len(allStreams) == 0 or allStreams[^1].kind != ContainerKind:
    error("Invalid media type")

  return allStreams

export getAllStreams, StreamKind
