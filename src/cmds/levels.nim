import std/options
import std/[strformat, strutils]

import ../av
import ../ffmpeg
import ../analyze/[audio, motion, subtitle]
import ../log
import ../cache

import tinyre

# TODO: Make a generic version
proc parseEditString*(exportStr: string): (string, float32, int32, int32, int32, Re) =
  var
    kind = exportStr
    threshold: float32 = 0.04
    stream: int32 = 0
    width: int32 = 400
    blur: int32 = 9
    pattern: Re = re("")

  let colonPos = exportStr.find(':')
  if colonPos == -1:
    return (kind, threshold, stream, width, blur, pattern)

  kind = exportStr[0..colonPos-1]
  let paramsStr = exportStr[colonPos+1..^1]

  var i = 0
  while i < paramsStr.len:
    while i < paramsStr.len and paramsStr[i] == ' ':
      inc i

    if i >= paramsStr.len:
      break

    var paramStart = i
    while i < paramsStr.len and paramsStr[i] != '=':
      inc i

    if i >= paramsStr.len:
      break

    let paramName = paramsStr[paramStart..i-1]
    inc i

    var value = ""
    if i < paramsStr.len and paramsStr[i] == '"':
      inc i
      while i < paramsStr.len:
        if paramsStr[i] == '\\' and i + 1 < paramsStr.len:
          # Handle escape sequences
          inc i
          case paramsStr[i]:
            of '"': value.add('"')
            of '\\': value.add('\\')
            else:
              value.add('\\')
              value.add(paramsStr[i])
        elif paramsStr[i] == '"':
          inc i
          break
        else:
          value.add(paramsStr[i])
        inc i
    else:
      # Unquoted value (until comma or end)
      while i < paramsStr.len and paramsStr[i] != ',':
        value.add(paramsStr[i])
        inc i

    case paramName:
      of "stream": stream = parseInt(value).int32
      of "threshold": threshold = parseFloat(value).float32
      of "width": width = parseInt(value).int32
      of "blur": blur = parseInt(value).int32
      of "pattern":
        try:
          pattern = re(value)
        except ValueError:
          error &"Invalid regex expression: {value}"
      else: error &"Unknown paramter: {paramName}"

    # Skip comma
    if i < paramsStr.len and paramsStr[i] == ',':
      inc i

  return (kind, threshold, stream, width, blur, pattern)

type levelArgs* = object
  timebase*: string = "30/1"
  edit*: string = "audio"
  noCache*: bool = false

proc main*(strArgs: seq[string]) =
  if strArgs.len < 1:
    echo "Display loudness over time"
    quit(0)

  var args = levelArgs()
  var expecting: string = ""
  var inputFile: string = ""

  for key in strArgs:
    case key
    of "--no-cache":
      args.noCache = true
    of "-tb":
      expecting = "timebase"
    of "--timebase", "--edit":
      expecting = key[2..^1]
    else:
      if key.startsWith("--"):
        error(fmt"Unknown option: {key}")

      case expecting
      of "":
        inputFile = key
      of "timebase":
        args.timebase = key
      of "edit":
        args.edit = key
      expecting = ""

  if expecting != "":
    error(fmt"--{expecting} needs argument.")

  if inputFile == "":
    error("Expecting an input file.")

  av_log_set_level(AV_LOG_QUIET)
  let tb = AVRational(args.timebase)
  let chunkDuration: float64 = av_inv_q(tb)
  let (editMethod, _, userStream, width, blur, pattern) = parseEditString(args.edit)
  if editMethod notin ["audio", "motion", "subtitle"]:
    error fmt"Unknown editing method: {editMethod}"

  let cacheArgs = (if editMethod == "audio": $userStream else: &"{userStream},{width},{blur}")

  if userStream < 0:
    error "Stream must be positive"

  echo "\n@start"

  if not args.noCache:
    let cacheData = readCache(inputFile, tb, editMethod, cacheArgs)
    if cacheData.isSome:
      for loudnessValue in cacheData.get():
        echo loudnessValue
      echo ""
      return

  var container: InputContainer
  var data: seq[float32] = @[]

  try:
    container = av.open(inputFile)
  except IOError as e:
    error e.msg
  defer: container.close()

  if editMethod == "audio":
    if container.audio.len == 0:
      error "No audio stream"
    if container.audio.len <= userStream:
      error fmt"Audio stream out of range: {userStream}"

    let audioStream: ptr AVStream = container.audio[userStream]
    var processor = AudioProcessor(
      formatCtx: container.formatContext,
      codecCtx: initDecoder(audioStream.codecpar),
      audioIndex: audioStream.index,
      chunkDuration: chunkDuration
    )

    for loudnessValue in processor.loudness():
      echo loudnessValue
      data.add loudnessValue
    echo ""

  elif editMethod == "motion":
    if container.video.len == 0:
      error "No audio stream"
    if container.video.len <= userStream:
      error fmt"Video stream out of range: {userStream}"

    let videoStream: ptr AVStream = container.video[userStream]
    var processor = VideoProcessor(
      formatCtx: container.formatContext,
      codecCtx: initDecoder(videoStream.codecpar),
      videoIndex: videoStream.index,
      width: width,
      blur: blur,
      tb: tb,
    )

    for value in processor.motionness():
      echo value
      data.add value
    echo ""

  elif editMethod == "subtitle":
    if container.subtitle.len == 0:
      error "No Subtitle stream"
    if container.subtitle.len <= userStream:
      error fmt"Subtitle stream out of range: {userStream}"

    for value in subtitle(container, tb, pattern, userStream):
      echo (if value: "1" else: "0")

  if editMethod != "subtitle" and not args.noCache:
    writeCache(data, inputFile, tb, editMethod, cacheArgs)
