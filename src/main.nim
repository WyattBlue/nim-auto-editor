import std/os
import std/[strformat, strutils]
import std/enumerate
import std/json
import ffmpeg
import media
import levels
import av


proc genericTrack(lang: string, bitrate: int) =
  if bitrate != 0:
    echo fmt"     - bitrate: {bitrate}"
  if lang != "und":
    echo fmt"     - lang: {lang}"

proc printYamlInfo(fileInfo: MediaInfo) =
  echo fileInfo.path, ":"

  if fileInfo.v.len > 0:
    echo fmt" - video:"
  for track, v in enumerate(fileInfo.v):
    echo fmt"   - track {track}:"
    echo fmt"     - codec: {v.codec}"
    echo fmt"     - fps: {v.avg_rate.num}/{v.avg_rate.den}"
    echo fmt"     - resolution: {v.width}x{v.height}"
    # echo fmt"     - aspect ratio: {v.aspectRatio}"
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
    varr.add(
      %* {"codec": v.codec, "fps": v.avg_rate.fracToHuman, "resolution": [v.width, v.height], "timebase": v.timebase, "bitrate": v.bitrate, "lang": v.lang}
    )

  for a in fileInfo.a:
    aarr.add(%* a)

  for s in fileInfo.s:
    sarr.add(%* s)

  var content = %* {"type": "media", "recommendedTimebase": fileInfo.recommendedTimebase, "video": varr, "audio": aarr, "subtitle": sarr}
  var j = %* {fileInfo.path: content}
  echo j


proc main() =
  if paramCount() < 1:
    echo """Auto-Editor is an automatic video/audio creator and editor. By default, it
will detect silence and create a new video with those sections cut out. By
changing some of the options, you can export to a traditional editor like
Premiere Pro and adjust the edits there, adjust the pacing of the cuts, and
change the method of editing like using audio loudness and video motion to
judge making cuts.
"""
    quit(0)

  if paramCount() < 2:
    quit(1)

  if paramStr(1) == "levels":
    levels.main(paramStr(2))
    quit(0)
  elif paramStr(1) != "info":
    echo "unknown subcommand"
    quit(1)

  let inputFile = paramStr(2)

  var isJson: bool
  if paramCount() >= 3 and paramStr(3) == "--json":
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


when isMainModule:
  main()