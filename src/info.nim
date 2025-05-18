import av
import std/json
import std/enumerate
import std/[strformat, strutils]
import media

proc genericTrack(lang: string, bitrate: int) =
  if bitrate != 0:
    echo fmt"     - bitrate: {bitrate}"
  if lang != "und":
    echo fmt"     - lang: {lang}"


func aspectRatio(width, height: int): tuple[w, h: int] =
  if height == 0:
    return (0, 0)

  func gcd(a, b: int): int =
    var
      x = a
      y = b
    while y != 0:
      (x, y) = (y, x mod y)
    return x

  let c = gcd(width, height)
  return (width div c, height div c)

proc printYamlInfo(fileInfo: MediaInfo) =
  echo fileInfo.path, ":"

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
    echo fmt"     - color transfer: {v.color_trc}"
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

  echo " - container:"
  if fileInfo.duration != 0.0:
    echo fmt"   - duration: {fileInfo.duration:.1f}"
  echo fmt"   - bitrate: {fileInfo.bitrate}"

proc printJsonInfo(fileInfo: MediaInfo) =
  var
    varr: seq[JsonNode] = @[]
    aarr: seq[JsonNode] = @[]
    sarr: seq[JsonNode] = @[]

  for v in fileInfo.v:
    let (ratioWidth, ratioHeight) = aspectRatio(v.width, v.height)
    varr.add( %* {
      "codec": v.codec,
      "fps": v.avg_rate.fracToHuman,
      "resolution": [v.width, v.height],
      "aspect_ratio": [ratioWidth, ratioHeight],
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

  var content = %* {
    "type": "media",
    "recommendedTimebase": fileInfo.recommendedTimebase,
    "video": varr,
    "audio": aarr,
    "subtitle": sarr,
    "container": {
      "duration": fileInfo.duration,
      "bitrate": fileInfo.bitrate
    }
  }
  var j = %* {fileInfo.path: content}
  echo pretty(j)


proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Retrieve information and properties about media files"
    quit(0)

  let inputFile = args[0]

  var isJson: bool
  if args.len >= 2 and args[1] == "--json":
    isJson = true
  else:
    isJson = false

  var container = av.open(inputFile)
  let MediaInfo = initMediaInfo(container.formatContext, inputFile)
  container.close()

  if isJson:
    printJsonInfo(MediaInfo)
  else:
    printYamlInfo(MediaInfo)
