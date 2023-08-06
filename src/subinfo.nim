import std/algorithm
import std/enumerate
import std/strformat
import std/strutils
import std/rationals

import ffwrapper
import util

const lbrac = "{"
const rbrac = "}"

func jsonEscape(val: string): string =
  var buf = ""
  for c in val:
    if c == '"':
      buf &= "\\\""
    elif c == '\\':
      buf &= "\\\\"
    else:
      buf &= c
  return buf

type
  Args = object
    json: bool
    input: string
    ff_loc: string


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
     - aspect ratio: {stream.dar.num}:{stream.dar.den}
     - pixel aspect ratio: {stream.sar.num}:{stream.sar.den}
     - pix_fmt: {stream.pix_fmt}"""
    if stream.duration != 0.0:
      echo &"     - duration: {stream.duration}"
    if stream.color_range != "unknown":
      echo &"     - color range: {stream.color_range}"
    if stream.color_space != "unknown":
      echo &"     - color space: {stream.color_space}"
    if stream.color_transfer != "unknown":
      echo &"     - color transfer: {stream.color_transfer}"
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
    if stream.duration != 0.0:
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
    "{jsonEscape(input)}": {lbrac}
        "type": "media",
        "video": ["""
  for i, stream in enumerate(reversed(Vs)):
    echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "fps": "{stream.fps}",
                "resolution": [{stream.width}, {stream.height}],
                "dar": [{stream.dar.num}, {stream.dar.den}],
                "sar": [{stream.sar.num}, {stream.sar.den}],
                "duration": {stream.duration},
                "pix_fmt": "{stream.pix_fmt}",
                "color_range": "{stream.color_range}",
                "color_space": "{stream.color_space}",
                "color_primaries": "{stream.color_primaries}",
                "color_transfer": "{stream.color_transfer}",
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
                "duration": {stream.duration},
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
            "duration": {container.duration},
            "bitrate": {container.bitrate}
        {rbrac}
    {rbrac}
{rbrac}
"""

proc info(args: seq[string]) =
  var
    i = 1
    arg: string
    p: Args = Args(input: "", json: false, ff_loc: "ffprobe")

  while i < len(args):
    arg = args[i]

    if arg == "--help" or arg == "-h":
      echo """Usage: [file ...] [options]

Options:
  --json                            Export info in JSON format
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
    echo "Retrieve information and properties about media files"
    system.quit(1)

  let allStreams = getAllStreams(p.ff_loc, p.input, initLog())

  if p.json:
    display_stream_json(p.input, allStreams)
  else:
    display_stream(p.input, allStreams)

export info
