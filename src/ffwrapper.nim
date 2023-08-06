import std/osproc
import std/strutils except parseFloat
import std/strformat
import std/rationals
from std/parseutils import parseFloat

import util

type
  VideoStream* = ref object
    duration*: float = 0.0
    bitrate*: uint64 = 0
    codec*: string
    lang*: string = ""
    width*: uint64
    height*: uint64
    fps*: string
    timebase*: string
    dar*: Rational[int] = 0//1
    sar*: Rational[int] = 1//1
    pix_fmt*: string
    color_range*: string
    color_space*: string
    color_transfer*: string
    color_primaries*: string

  AudioStream* = ref object
    duration*: float = 0.0
    bitrate*: uint64 = 0
    codec*: string
    lang*: string = ""
    sampleRate*: uint64
    channels*: uint64

  SubtitleStream* = ref object
    duration*: float = 0.0
    bitrate*: uint64 = 0
    codec*: string
    lang*: string = ""

  DataStream* = ref object
    duration*: float = 0.0
    bitrate*: uint64 = 0
    codec*: string
    lang*: string = ""

  StreamKind* = enum
    UnknownKind,
    VideoKind,
    AudioKind,
    SubtitleKind,
    DataKind,
    ContainerKind,

  FileInfo* = ref object
    path*: string
    duration*: float = 0.0
    bitrate*: uint64 = 0
    lang*: string
    v*: seq[VideoStream]
    a*: seq[AudioStream]
    s*: seq[SubtitleStream]
    d*: seq[DataStream]


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


proc initFileInfo(ffLoc: string, input: string, log: Log): FileInfo =
  var ffout: string
  try:
    ffout = execProcess(ffLoc,
      args = ["-v", "-8", "-show_streams", "-show_format", input],
      options = {poUsePath}
    )
  except OSError:
    log.error(&"Invalid ffprobe location: {ffLoc}")

  var
    foo: seq[string]
    key: string
    val: string
    vs: seq[VideoStream] = @[]
    `as`: seq[AudioStream] = @[]
    ss: seq[SubtitleStream] = @[]
    ds: seq[DataStream] = @[]
    codec: string
    conDuration = 0.0
    conBitrate: uint64 = 0
    conLang = ""
    streamType: StreamKind = UnknownKind

  for line in splitLines(ffout):
    if line == "" or line.startswith("[/"):
      continue

    if line.startswith("["):
      if line == "[FORMAT]":
        streamType = ContainerKind
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
        streamType = VideoKind
        vs.add(VideoStream(codec: codec, color_transfer: "unknown"))
      elif val == "audio":
        streamType = AudioKind
        `as`.add(AudioStream(codec: codec))
      elif val == "subtitle":
        streamType = SubtitleKind
        ss.add(SubtitleStream(codec: codec))
      else:
        streamType = DataKind
        ds.add(DataStream(codec: codec))

    if streamType == ContainerKind:
      if key == "bit_rate" and val != "N/A":
        conBitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, conDuration, 0)
      if key == "lang":
        conLang = val

    if streamType == VideoKind and len(vs) > 0:
      if key == "bit_rate" and val != "N/A":
        vs[^1].bitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, vs[^1].duration, 0)
      if key == "lang":
        vs[^1].lang = val

      if key == "width":
        vs[^1].width = parseUInt(val)
      if key == "height":
        vs[^1].height = parseUInt(val)
      if key == "avg_frame_rate":
        vs[^1].fps = val
      if key == "sample_aspect_ratio" and val != "N/A":
        vs[^1].sar = parseRational(val)
      if key == "display_aspect_ratio" and val != "N/A":
        vs[^1].dar = parseRational(val)
      if key == "time_base":
        vs[^1].timebase = val

      if key == "pix_fmt":
        vs[^1].pix_fmt = val
      if key == "color_range":
        vs[^1].color_range = val
      if key == "color_space":
        vs[^1].color_space = val
      if key == "color_transfer":
        vs[^1].color_transfer = val
      if key == "color_primaries":
        vs[^1].color_primaries = val

    if streamType == AudioKind and len(`as`) > 0:
      if key == "bit_rate" and val != "N/A":
        `as`[^1].bitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, `as`[^1].duration, 0)
      if key == "lang":
        `as`[^1].lang = val

      if key == "sample_rate":
        `as`[^1].sampleRate = parseUInt(val)
      if key == "channels":
        `as`[^1].channels = parseUInt(val)

    if streamType == SubtitleKind and len(ss) > 0:
      if key == "bit_rate" and val != "N/A":
        ss[^1].bitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, ss[^1].duration, 0)
      if key == "lang":
        ss[^1].lang = val

    if streamType == DataKind and len(ds) > 0:
      if key == "bit_rate" and val != "N/A":
        ds[^1].bitrate = parseUInt(val)
      if key == "duration":
        discard parseFloat(val, ds[^1].duration, 0)
      if key == "lang":
        ds[^1].lang = val

  if len(vs) == 0 and len(`as`) == 0:
    log.error("Invalid media type")


  return FileInfo(path: input, duration: conDuration, bitrate: conBitrate,
    lang: conLang, v: vs, a: `as`, s: ss, d: ds,
  )

export StreamKind, FileInfo, VideoStream, AudioStream, SubtitleStream, DataStream, initFileInfo
