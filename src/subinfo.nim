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

  Stream = ref object
    codec: string
    lang: string
    duration: string
    bitrate: uint64
    case kind: StreamKind
    of VideoKind:
      width: uint64
      height: uint64
      fps: string # Rational[int64]
      sar: string
      pix_fmt: string
      color_range: string
      color_space: string
      color_primaries: string
    of AudioKind:
      sampleRate: uint64
      channels: uint64

  ReaderKind = enum
    unknownT,
    unknownStreamT,
    audioStreamT,
    videoStreamT,
    formatT,


proc display_stream(stream: Stream) =
  if stream.kind == VideoKind:
    echo &"""
 - codec: {stream.codec}
 - fps: {stream.fps}
 - resolution: {stream.width}x{stream.height}
 - pix_fmt: {stream.pix_fmt}
 - color range: {stream.color_range}
 - color space: {stream.color_space}
 - color primaries: {stream.color_primaries}
 - bitrate: {stream.bitrate}
 - lang: {stream.lang}
"""
  elif stream.kind == AudioKind:
    echo &"""
 - codec: {stream.codec}
 - samplerate: {stream.sampleRate}
 - channels: {stream.channels}
 - bitrate: {stream.bitrate}
 - lang: {stream.lang}
"""

proc info(args: seq[string]) =
  # tod: "ffprobe" literal needs to be changed
  let ffout = execProcess("ffprobe",
    args=["-v", "-8", "-show_streams", "-show_format", args[1]],
    options={poUsePath}
  )
  echo ffout
  var
    current = unknownT
    foo: seq[string]
    key: string
    val: string
    codec_name: string
    my_stream: Stream
    stream_defined: bool = false

  for line in splitLines(ffout):
    if line.startswith("[/"):
      current = unknownT
      continue
    if line == "[STREAM]":
      current = unknownStreamT
      continue
    if line == "":
      continue
    if line.startswith("["):
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
        my_stream = Stream(codec: codec_name, lang: "null", kind: VideoKind)
      elif val == "audio":
        my_stream = Stream(codec: codec_name, lang: "null", kind: AudioKind)
      else:
        raise newException(IOError, "Unknown codec type")

    if stream_defined:
      if key == "lang":
        my_stream.lang = val
      if key == "bit_rate":
        my_stream.bitrate = parseUInt(val)
      if key == "duration":
        my_stream.duration = val

      if my_stream.kind == VideoKind:
        if key == "width":
          my_stream.width = parseUInt(val)
        if key == "height":
          my_stream.height = parseUInt(val)
        if key == "avg_frame_rate":
          my_stream.fps = val

        if key == "pix_fmt":
          my_stream.pix_fmt = val
        if key == "color_range":
          my_stream.color_range = val
        if key == "color_space":
          my_stream.color_space = val
        if key == "color_primaries":
          my_stream.color_primaries = val
      if my_stream.kind == AudioKind:
        if key == "sample_rate":
          my_stream.sampleRate = parseUInt(val)
        if key == "channels":
          my_stream.channels = parseUInt(val)

  if stream_defined:
    display_stream(my_stream)
export info