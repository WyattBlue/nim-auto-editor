import osproc
import std/strutils
import std/strformat
# import std/rationals

# TODO: If ffmpeg's language codes are short enough
# Make language datatype a char array
type
  StreamKind = enum
    VideoKind,
    AudioKind,
    SubtitleKind,
    ContainerKind,

  Stream = ref object
    duration: string
    bitrate: uint64
    case kind: StreamKind
    of VideoKind:
      vcodec: string
      width: uint64
      height: uint64
      fps: string # Rational[int64]
      timebase: string
      aspect_ratio: string
      sar: string
      pix_fmt: string
      color_range: string
      color_space: string
      color_primaries: string
      vlang: string
    of AudioKind:
      acodec: string
      sampleRate: uint64
      channels: uint64
      alang: string
    of SubtitleKind:
      scodec: string
      slang: string
    of ContainerKind:
      idk: int64

  ReaderKind = enum
    unknownT,
    streamT,
    formatT,


var
  vtracks: uint64 = 0
  atracks: uint64 = 0
  stracks: uint64 = 0

proc display_stream(stream: Stream) =
  if stream.kind == VideoKind:
    echo &"""   - track {vtracks - 1}:
     - codec: {stream.vcodec}
     - fps: {stream.fps}
     - resolution: {stream.width}x{stream.height}
     - aspect ratio: {stream.aspect_ratio}
     - pixel aspect ratio: {stream.sar}
     - duration: {stream.duration}
     - pix_fmt: {stream.pix_fmt}
     - color range: {stream.color_range}
     - color space: {stream.color_space}
     - color primaries: {stream.color_primaries}
     - timebase: {stream.timebase}
     - bitrate: {stream.bitrate}
     - lang: {stream.vlang}"""
  elif stream.kind == AudioKind:
    echo &"""   - track {atracks - 1}:
     - codec: {stream.acodec}
     - samplerate: {stream.sampleRate}
     - channels: {stream.channels}
     - duration: {stream.duration}
     - bitrate: {stream.bitrate}
     - lang: {stream.alang}"""
  elif stream.kind == SubtitleKind:
    echo &"""   - track {stracks - 1}:
     - codec: {stream.scodec}
     - lang: {stream.slang}"""
  elif stream.kind == ContainerKind:
    echo &""" - container:
   - duration: {stream.duration}
   - bitrate: {stream.bitrate}
"""

proc info(args: seq[string]) =
  # tod: "ffprobe" literal needs to be changed
  let ffout = execProcess("ffprobe",
    args=["-v", "-8", "-show_streams", "-show_format", args[1]],
    options={poUsePath}
  )
  var
    current = unknownT
    foo: seq[string]
    key: string
    val: string
    codec_name: string
    my_stream: Stream
    stream_defined: bool = false

  for line in splitLines(ffout):
    if line == "" or line.startswith("[/"):
      continue

    if line.startswith("["):
      if line == "[STREAM]":
        current = streamT
      if line == "[FORMAT]":
        if stream_defined:
          display_stream(my_stream)
        stream_defined = true
        my_stream = Stream(kind: ContainerKind)
        current = formatT
      continue

    if line.startswith("TAG:language="):
      key = "lang"
      val = line[13 .. ^1]
    elif line.startswith("TAG:"):
      continue

    if not line.startswith("TAG:"):
      foo = line.split("=")
      if len(foo) != 2:
        echo &"The invalid line: {line}"
        raise newException(IOError, "Invalid key value pair")

      key = foo[0]
      val = foo[1]

    if key == "codec_name":
      codec_name = val

    if key == "codec_type":
      if stream_defined:
        display_stream(my_stream)
      stream_defined = true
      if val == "video":
        my_stream = Stream(kind: VideoKind, vcodec: codec_name, vlang: "null")
        if vtracks == 0:
          echo " - video:"
        vtracks += 1
      elif val == "audio":
        my_stream = Stream(kind: AudioKind, acodec: codec_name, alang: "null")
        if atracks == 0:
          echo " - audio:"
        atracks += 1
      elif val == "subtitle":
        my_stream = Stream(kind: SubtitleKind, scodec: codec_name, slang: "null")
        if stracks == 0:
          echo " - subtitle:"
        stracks += 1
      else:
        raise newException(IOError, "Unknown codec type")

    if stream_defined:
      if key == "bit_rate":
        my_stream.bitrate = parseUInt(val)
      if key == "duration":
        my_stream.duration = val

      if my_stream.kind == VideoKind:
        if key == "lang":
          my_stream.vlang = val
        if key == "width":
          my_stream.width = parseUInt(val)
        if key == "height":
          my_stream.height = parseUInt(val)
        if key == "avg_frame_rate":
          my_stream.fps = val
        if key == "sample_aspect_ratio":
          my_stream.sar = val
        if key == "display_aspect_ratio":
          my_stream.aspect_ratio = val
        if key == "time_base":
          my_stream.timebase = val

        if key == "pix_fmt":
          my_stream.pix_fmt = val
        if key == "color_range":
          my_stream.color_range = val
        if key == "color_space":
          my_stream.color_space = val
        if key == "color_primaries":
          my_stream.color_primaries = val

      if my_stream.kind == AudioKind:
        if key == "lang":
          my_stream.alang = val
        if key == "sample_rate":
          my_stream.sampleRate = parseUInt(val)
        if key == "channels":
          my_stream.channels = parseUInt(val)

      if my_stream.kind == SubtitleKind:
        if key == "lang":
          my_stream.slang = val

  if stream_defined:
    display_stream(my_stream)
export info
