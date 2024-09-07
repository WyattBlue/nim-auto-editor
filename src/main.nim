import std/os
import std/[strformat, strutils]
import std/enumerate
import std/json
import ffmpeg
import media


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
    echo fmt"     - duration: {a.duration:.1f}"
    genericTrack(a.lang, a.bitrate)

  if fileInfo.s.len > 0:
    echo fmt" - subtitle:"
  for track, s in enumerate(fileInfo.s):
    echo fmt"   - track {track}:"
    echo fmt"     - codec: {s.codec}"
    genericTrack(s.lang, s.bitrate)

  echo " - container:"
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

  if paramCount() < 2 or paramStr(1) != "info":
    quit(1)

  let inputFile = paramStr(2)

  var isJson: bool
  if paramCount() >= 3 and paramStr(3) == "--json":
    isJson = true
  else:
    isJson = false

  var formatContext: ptr AVFormatContext

  if avformat_open_input(addr formatContext, inputFile.cstring, nil, nil) != 0:
    echo "Could not open input file: ", inputFile
    quit(1)

  if avformat_find_stream_info(formatContext, nil) < 0:
    echo "Could not find stream information"
    avformat_close_input(addr formatContext)
    quit(1)

  let MediaInfo = initMediaInfo(formatContext, inputFile)
  avformat_close_input(addr formatContext)

  if isJson:
    printJsonInfo(MediaInfo)
  else:
    printYamlInfo(MediaInfo)


when isMainModule:
  main()