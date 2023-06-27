import osproc
import std/strutils
import std/strformat
import std/enumerate
import algorithm
# import math (for gcd)
# import std/rationals

const lbrac = "{"
const rbrac = "}"

proc error(msg: string) =
  stderr.writeLine(&"Error! {msg}")
  system.quit(1)

type
  Args = object
    json: bool
    input: string
    ff_loc: string

  StreamKind = enum
    VideoKind,
    AudioKind,
    SubtitleKind,
    ContainerKind,
    DataKind,

  Stream = ref object
    duration: string
    bitrate: uint64
    codec: string
    lang: string
    case kind: StreamKind
    of VideoKind:
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
    of AudioKind:
      sampleRate: uint64
      channels: uint64
    of SubtitleKind:
      discard
    of ContainerKind:
      discard
    of DataKind:
      discard


proc display_stream(input: string, streams: seq[Stream]) =
  var
    allStreams = streams # Cast as mutable
    Vs: seq[Stream]
    As: seq[Stream]
    Ss: seq[Stream]
    container: Stream = allStreams[^1]
    temp: Stream

  while len(allStreams) > 0:
    temp = allStreams.pop()
    if temp.kind == VideoKind:
      Vs.add(temp)
    if temp.kind == AudioKind:
      As.add(temp)
    if temp.kind == SubtitleKind:
      Ss.add(temp)

  echo &"{input}:"
  for i, stream in enumerate(reversed(Vs)):
    if i == 0:
      echo " - video:"
    echo &"""
   - track {i}:
     - codec: {stream.codec}
     - fps: {stream.fps}
     - timebase: {stream.timebase}
     - resolution: {stream.width}x{stream.height}
     - aspect ratio: {stream.aspect_ratio}
     - pixel aspect ratio: {stream.sar}
     - pix_fmt: {stream.pix_fmt}"""
    if stream.duration != "N/A":
      echo &"     - duration: {stream.duration}"
    if stream.color_range != "unknown":
      echo &"     - color range: {stream.color_range}"
    if stream.color_space != "unknown":
      echo &"     - color space: {stream.color_space}"
    if stream.color_primaries != "unknown":
      echo &"     - color primaries: {stream.color_primaries}"
    if stream.bitrate != 0:
      echo &"     - bitrate: {stream.bitrate}"
    if stream.lang != "":
      echo &"     - lang: {stream.lang}"

  for i, stream in enumerate(reversed(As)):
    if i == 0:
      echo " - audio:"
    echo &"""
   - track {i}:
     - codec: {stream.codec}
     - samplerate: {stream.sampleRate}
     - channels: {stream.channels}"""
    if stream.duration != "N/A":
      echo &"     - duration: {stream.duration}"
    if stream.bitrate != 0:
      echo &"     - bitrate: {stream.bitrate}"
    if stream.lang != "":
      echo &"     - lang: {stream.lang}"
  for i, stream in enumerate(reversed(Ss)):
    if i == 0:
      echo " - subtitle:"
    echo &"""
   - track {i}:
     - codec: {stream.codec}"""
    if stream.lang != "":
      echo &"     - lang: {stream.lang}"

  echo &"""
 - container:
   - duration: {container.duration}
   - bitrate: {container.bitrate}
"""

proc display_stream_json(input: string, streams: seq[Stream]) =
  var
    allStreams = streams # Cast as mutable
    Vs: seq[Stream]
    As: seq[Stream]
    Ss: seq[Stream]
    container: Stream = allStreams[^1]
    temp: Stream

  while len(allStreams) > 0:
    temp = allStreams.pop()
    if temp.kind == VideoKind:
      Vs.add(temp)
    if temp.kind == AudioKind:
      As.add(temp)
    if temp.kind == SubtitleKind:
      Ss.add(temp)

  echo &"""{lbrac}
    "{input}": {lbrac}
        "type": "media",
        "video": ["""
  for i, stream in enumerate(reversed(Vs)):
    echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "fps": "{stream.fps}",
                "resolution": [{stream.width}, {stream.height}],
                "aspect_ratio": [16, 9],
                "pixel_aspect_ratio": "{stream.sar}",
                "duration": "{stream.duration}",
                "pix_fmt": "{stream.pix_fmt}",
                "color_range": "{stream.color_range}",
                "color_space": "{stream.color_space}",
                "color_primaries": "{stream.color_primaries}",
                "color_transfer": "",
                "timebase": "{stream.timebase}",
                "bitrate": {stream.bitrate},
                "lang": "{stream.lang}"
            {rbrac}"""
    if i == len(Vs) - 1:
      stdout.write ""
    else:
      stdout.write ","

  echo "        ],\n        \"audio\": ["
  for i, stream in enumerate(reversed(As)):
    echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "samplerate": {stream.sampleRate},
                "channels": {stream.channels},
                "duration": "{stream.duration}",
                "bitrate": {stream.bitrate},
                "lang": "{stream.lang}"
            {rbrac}"""
    if i == len(As) - 1:
      echo ""
    else:
      echo ","
  echo "        ],\n        \"subtitle\": ["
  for i, stream in enumerate(reversed(Ss)):
    echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "lang": "{stream.lang}"
            {rbrac}"""
    if i == len(Ss) - 1:
      echo ""
    else:
      echo ","
  echo &"""        ],
        "container": {lbrac}
            "duration": "{container.duration}",
            "bitrate": {container.bitrate}
        {rbrac}
    {rbrac}
{rbrac}
"""

proc info(args: seq[string]) =
  var
    i = 1
    arg: string
    p: Args = Args(input:"", json: false, ff_loc:"ffprobe")

  while i < len(args):
    arg = args[i]

    if arg == "--help" or arg == "-h":
      echo """Usage: [file ...] [options]

Options:
  --json                            Export info in JSON format
  --has-vfr, --include-vfr          Display the number of Variable Frame Rate
                                    (VFR) frames
  --ffprobe-location                Point to your custom ffprobe file
  -h, --help                        Show info about this program or option
                                    then exit
"""
      system.quit(1)


    elif arg == "--json":
      p.json = true
    elif arg == "--ffprobe-location":
      p.ff_loc = args[i + 1]
      i += 1
    else:
      p.input = arg

    i += 1

  if p.input == "":
    error("Retrieve information and properties about media files")

  let ffout = execProcess(p.ff_loc,
    args=["-v", "-8", "-show_streams", "-show_format", p.input],
    options={poUsePath}
  )
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
        allStreams.add(Stream(kind: ContainerKind, duration: "N/A", bitrate: 0))
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
        allStreams.add(Stream(kind: VideoKind, codec: codec, lang: "", sar: "1:1"))
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
        allStreams[^1].duration = val
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
          allStreams[^1].sar = val
        if key == "display_aspect_ratio":
          allStreams[^1].aspect_ratio = val
        if key == "time_base":
          allStreams[^1].timebase = val

        if key == "pix_fmt":
          allStreams[^1].pix_fmt = val
        if key == "color_range":
          allStreams[^1].color_range = val
        if key == "color_space":
          allStreams[^1].color_space = val
        if key == "color_primaries":
          allStreams[^1].color_primaries = val

      if allStreams[^1].kind == AudioKind:
        if key == "sample_rate":
          allStreams[^1].sampleRate = parseUInt(val)
        if key == "channels":
          allStreams[^1].channels = parseUInt(val)

  if len(allStreams) == 0 or allStreams[^1].kind != ContainerKind:
    error("Invalid media type")

  if p.json:
    display_stream_json(p.input, allStreams)
  else:
    display_stream(p.input, allStreams)
export info
