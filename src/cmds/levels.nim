import std/parseopt
import std/[strformat, strutils]

import ../av
import ../ffmpeg
import ../analyze
import ../log

type levelArgs* = object
  input*: string
  timebase*: string = "30/1"
  edit*: string = "audio"

# TODO: Make a generic version
proc parseEditString*(exportStr: string): (string, string, string) =
  var kind = exportStr
  var stream = "0"
  var threshold = ""

  let colonPos = exportStr.find(':')
  if colonPos == -1:
    return (kind, stream, threshold)

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
      of "stream": stream = value
      of "threshold": threshold = value

    # Skip comma
    if i < paramsStr.len and paramsStr[i] == ',':
      inc i

  return (kind, stream, threshold)

proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Display loudness over time"
    quit(0)

  var args = levelArgs()
  var expecting: string = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      case expecting
      of "":
        args.input = key
      of "timebase":
        args.timebase = key
      of "edit":
        args.edit = key
      expecting = ""

    of cmdLongOption:
      if key in ["edit", "timebase"]:
        expecting = key
      else:
        error(fmt"Unknown option: {key}")
    of cmdShortOption:
      if key == "t":
        discard
      elif key == "b":
        expecting = "timebase"
      else:
        error(fmt"Unknown option: {key}")
    of cmdEnd:
      discard

  if expecting != "":
    error(fmt"--{expecting} needs argument.")

  av_log_set_level(AV_LOG_QUIET)
  let inputFile = args.input
  let chunkDuration: float64 = av_inv_q(AVRational(args.timebase))
  let (editMethod, streamStr, _) = parseEditString(args.edit)
  if editMethod != "audio":
    error fmt"Unknown editing method: {editMethod}"
  let userStream = parseInt(streamStr)

  var container: InputContainer
  try:
    container = av.open(inputFile)
  except IOError as e:
    error e.msg
  defer: container.close()

  if container.audio.len == 0:
    error "No audio stream"
  if userStream < 0:
    error "Stream must be positive"
  if container.audio.len <= userStream:
    error fmt"Audio stream out of range: {userStream}"

  let audioStream: ptr AVStream = container.audio[userStream]
  let audioIndex: cint = audioStream.index

  var processor = AudioProcessor(
    formatCtx: container.formatContext,
    codecCtx: initDecoder(audioStream.codecpar),
    audioIndex: audioIndex,
    chunkDuration: chunkDuration
  )

  echo "\n@start"

  for loudnessValue in processor.loudness():
    echo loudnessValue

  echo ""