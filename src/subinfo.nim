import std/[algorithm, enumerate, rationals]
import std/[strformat, strutils]

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
    input: seq[string] = @[]
    json: bool = false
    ffLoc: string = "ffprobe"


proc display_stream(vids: seq[FileInfo]) =
  for vid in vids:
    echo &"{vid.path}:"
    for i, stream in enumerate(reversed(vid.v)):
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

    for i, stream in enumerate(reversed(vid.a)):
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

    for i, stream in enumerate(reversed(vid.s)):
      if i == 0:
        echo " - subtitle:"
      echo &"""
   - track {i}:
     - codec: {stream.codec}"""
      if stream.lang != "":
        echo &"     - lang: {stream.lang}"

    echo &"""
 - container:
   - duration: {vid.duration}
   - bitrate: {vid.bitrate}
"""

proc display_stream_json(vids: seq[FileInfo]) =
  echo "{"
  for j, vid in enumerate(vids):
    echo &"""    "{jsonEscape(vid.path)}": {lbrac}
        "type": "media",
        "video": ["""
    for i, stream in enumerate(reversed(vid.v)):
      echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "fps": "{stream.fps}",
                "timebase": "{stream.timebase}",
                "resolution": [{stream.width}, {stream.height}],
                "dar": [{stream.dar.num}, {stream.dar.den}],
                "sar": [{stream.sar.num}, {stream.sar.den}],
                "duration": {stream.duration},
                "pix_fmt": "{stream.pix_fmt}",
                "color_range": "{stream.color_range}",
                "color_space": "{stream.color_space}",
                "color_primaries": "{stream.color_primaries}",
                "color_transfer": "{stream.color_transfer}",
                "bitrate": {stream.bitrate},
                "lang": "{stream.lang}"
            {rbrac}{(if i == len(vid.v) - 1: "" else: ",")}"""

    echo "        ],\n        \"audio\": ["
    for i, stream in enumerate(reversed(vid.a)):
      echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "samplerate": {stream.sampleRate},
                "channels": {stream.channels},
                "duration": {stream.duration},
                "bitrate": {stream.bitrate},
                "lang": "{stream.lang}"
            {rbrac}{(if i == len(vid.a) - 1: "" else: ",")}"""

    echo "        ],\n        \"subtitle\": ["
    for i, stream in enumerate(reversed(vid.s)):
      echo &"""            {lbrac}
                "codec": "{stream.codec}",
                "lang": "{stream.lang}"
            {rbrac}{(if i == len(vid.s) - 1: "" else: ",")}"""

    echo &"""        ],
        "container": {lbrac}
            "duration": {vid.duration},
            "bitrate": {vid.bitrate}
        {rbrac}
    {rbrac}{(if j == len(vids) - 1: "" else: ",")}"""
  echo "}"

proc info(args: seq[string]) =
  var
    i = 1
    arg: string
    p: Args = Args()

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
      p.ffLoc = args[i + 1]
      i += 1
    else:
      p.input.add(arg)

    i += 1

  let log = initLog()

  if len(p.input) == 0:
    log.error("No input file selected")

    #echo "Retrieve information and properties about media files"
    #system.quit(1)

  var allFiles: seq[FileInfo] = @[]
  for file in p.input:
    allFiles.add(initFileInfo(p.ffLoc, file, log))

  if p.json:
    display_stream_json(allFiles)
  else:
    display_stream(allFiles)

export info
