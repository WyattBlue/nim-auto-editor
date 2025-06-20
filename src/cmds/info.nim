import std/json
import std/enumerate
import std/[strformat, strutils]

import ../av
import ../ffmpeg
import ../timeline
import ../media
import ../log

proc genericTrack(lang: string, bitrate: int) =
  if bitrate != 0:
    echo fmt"     - bitrate: {bitrate}"
  if lang != "und":
    echo fmt"     - lang: {lang}"


proc printYamlInfo(fileInfo: MediaInfo) =
  echo fileInfo.path, ":"

  var tb = AVRational(30)
  if fileInfo.v.len > 0:
    tb = makeSaneTimebase(fileInfo.v[0].avg_rate)
  echo fmt" - recommendedTimebase: {tb.num}/{tb.den}"

  if fileInfo.v.len > 0:
    echo fmt" - video:"
  for track, v in enumerate(fileInfo.v):
    let (ratioWidth, ratioHeight) = aspectRatio(v.width, v.height)

    echo fmt"   - track {track}:"
    echo fmt"     - codec: {v.codec}"
    echo fmt"     - fps: {v.avg_rate.num}/{v.avg_rate.den}"
    echo fmt"     - resolution: {v.width}x{v.height}"
    echo fmt"     - aspect ratio: {ratioWidth}:{ratioHeight}"
    echo fmt"     - pixel aspect ratio: {v.sar}"
    if v.duration != 0.0:
      echo fmt"     - duration: {v.duration:.1f}"
    echo fmt"     - pix fmt: {v.pix_fmt}"
    echo fmt"     - color range: {v.color_range}"
    echo fmt"     - color space: {v.color_space}"
    echo fmt"     - color primaries: {v.color_primaries}"
    echo fmt"     - color transfer: {v.color_transfer}"
    echo fmt"     - timebase: {v.timebase}"
    genericTrack(v.lang, v.bitrate)


  if fileInfo.a.len > 0:
    echo fmt" - audio:"
  for track, a in enumerate(fileInfo.a):
    echo fmt"   - track {track}:"
    echo fmt"     - codec: {a.codec}"
    echo fmt"     - layout: {a.layout}"
    echo fmt"     - samplerate: {a.samplerate}"
    if a.duration != 0.0:
      echo fmt"     - duration: {a.duration:.1f}"
    genericTrack(a.lang, a.bitrate)

  if fileInfo.s.len > 0:
    echo fmt" - subtitle:"
  for track, s in enumerate(fileInfo.s):
    echo fmt"   - track {track}:"
    echo fmt"     - codec: {s.codec}"
    genericTrack(s.lang, s.bitrate)

  if fileInfo.d.len > 0:
    echo fmt" - data:"
  for track, d in enumerate(fileInfo.d):
    echo fmt"   - track {track}:"
    echo fmt"     - codec: {d.codec}"
    echo fmt"     - timecode: {d.timecode}"

  echo " - container:"
  if fileInfo.duration != 0.0:
    echo fmt"   - duration: {fileInfo.duration:.1f}"
  echo fmt"   - bitrate: {fileInfo.bitrate}"


func getJsonInfo(fileInfo: MediaInfo): JsonNode =
  var
    varr: seq[JsonNode] = @[]
    aarr: seq[JsonNode] = @[]
    sarr: seq[JsonNode] = @[]

  var tb = AVRational(30)
  if fileInfo.v.len > 0:
    tb = makeSaneTimebase(fileInfo.v[0].avg_rate)

  for v in fileInfo.v:
    let (ratioWidth, ratioHeight) = aspectRatio(v.width, v.height)
    varr.add( %* {
      "codec": v.codec,
      "fps": $v.avg_rate,
      "resolution": [v.width, v.height],
      "aspect_ratio": [ratioWidth, ratioHeight],
      "pixel_aspect_ratio": v.sar,
      "duration": v.duration,
      "pix_fmt": v.pix_fmt,
      "color_range": v.color_range,
      "color_space": v.color_space,
      "color_primaries": v.color_primaries,
      "color_transfer": v.color_transfer,
      "timebase": v.timebase,
      "bitrate": v.bitrate,
      "lang": v.lang
    })

  for a in fileInfo.a:
    aarr.add( %* {"codec": a.codec, "layout": a.layout,
        "samplerate": a.sampleRate, "duration": a.duration,
        "bitrate": a.bitrate, "lang": a.lang})

  for s in fileInfo.s:
    sarr.add( %* s)

  result = %* {
    "type": "media",
    "recommendedTimebase": $tb.num & "/" & $tb.den,
    "video": varr,
    "audio": aarr,
    "subtitle": sarr,
    "container": {
      "duration": fileInfo.duration,
      "bitrate": fileInfo.bitrate
    }
  }


proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Retrieve information and properties about media files"
    quit(0)

  av_log_set_level(AV_LOG_QUIET)

  var isJson = false
  var inputFiles: seq[string] = @[]

  for key in args:
    if key == "--json":
      isJson = true
    else:
      if key.startsWith("--"):
        error &"Unknown option: {key}"
      inputFiles.add key

  var fileInfo: JsonNode = %* {}
  for inputFile in inputFiles:
    try:
      var container = av.open(inputFile)
      let mediaInfo = initMediaInfo(container.formatContext, inputFile)
      container.close()

      if isJson:
        fileInfo[inputFile] = getJsonInfo(mediaInfo)
      else:
        printYamlInfo(mediaInfo)
        echo ""

    except IOError:
      if isJson:
        fileInfo[inputFile] = %* {"type": "invalid"}
      else:
        echo inputFile & ""
        echo " - Invalid\n"

  if isJson:
    echo pretty(fileInfo)
