import std/os
import std/terminal
import std/[strutils, strformat]
import std/sequtils
from std/math import round, trunc

import av
import log
import media
import ffmpeg
import timeline
import util/bar
import cmds/levels
import analyze/[audio, motion]

import imports/json
import exports/[fcp7, fcp11, json, shotcut]

proc mediaLength*(container: InputContainer): float64 =
  # Get the mediaLength in seconds.

  var format_ctx = container.formatContext
  defer: container.close()

  var audioStreamIndex = -1 # Get the first audio stream
  for i in 0..<format_ctx.nb_streams:
    if format_ctx.streams[i].codecpar.codec_type == ffmpeg.AVMEDIA_TYPE_AUDIO:
      audioStreamIndex = int(i)
      break

  if audioStreamIndex != -1:
    var time_base: AVRational
    var packet = ffmpeg.av_packet_alloc()
    var biggest_pts: int64

    while ffmpeg.av_read_frame(format_ctx, packet) >= 0:
      if packet.stream_index == audioStreamIndex:
        if packet.pts != ffmpeg.AV_NOPTS_VALUE and packet.pts > biggest_pts:
          biggest_pts = packet.pts

      ffmpeg.av_packet_unref(packet)

    if packet != nil:
      ffmpeg.av_packet_free(addr packet)

    time_base = format_ctx.streams[audioStreamIndex].time_base
    return float64(biggest_pts.cdouble * time_base.cdouble)

  error("No audio stream found")


proc parseExportString*(exportStr: string): (string, string, string) =
  var kind = exportStr
  var name = "Auto-Editor Media Group"
  var version = "11"

  let colonPos = exportStr.find(':')
  if colonPos == -1:
    return (kind, name, version)

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
      of "name": name = value
      of "version": version = value

    # Skip comma
    if i < paramsStr.len and paramsStr[i] == ',':
      inc i

  return (kind, name, version)


proc chunkify(arr: seq[bool]): seq[(int64, int64, float64)] =
  var arr_len: int64 = arr.len
  var start: int64 = 0
  var j: int64 = 1
  while j < arr_len:
    if arr[j] != arr[j - 1]:
      let speed = (if arr[j-1] == true: 1.0 else: 99999.0)
      result.add (start, j, speed)
      start = j
    inc j
  result.add (start, arr_len, (if arr[j] == true: 1.0 else: 99999.0))


proc splitNumStr(val: string): (float64, string) =
  var index = 0
  for char in val:
    if char notin "0123456789_ .-":
      break
    index += 1
  let (num, unit) = (val[0 ..< index], val[index .. ^1])
  var floatNum: float64
  try:
    floatNum = parseFloat(num)
  except:
    error fmt"Invalid number: '{val}'"
  return (floatNum, unit)

proc parseTime(val: string, tb: float64): int64 =
  let (num, unit) = splitNumStr(val)
  if unit in ["s", "sec", "secs", "second", "seconds"]:
    return round(num * tb).int64
  if unit in ["min", "mins", "minute", "minutes"]:
    return round(num * tb * 60).int64
  if unit == "hour":
    return round(num * tb * 3600).int64
  if unit != "":
    error fmt"'{val}': Time format got unknown unit: `{unit}`"

  if num != trunc(num):
    error fmt"'{val}': Time format expects an integer"
  return num.int64

proc mutMargin*(arr: var seq[bool], startM: int, endM: int) =
  # Find start and end indexes
  var startIndex: seq[int] = @[]
  var endIndex: seq[int] = @[]
  let arrlen = len(arr)
  for j in 1 ..< arrlen:
    if arr[j] != arr[j - 1]:
      if arr[j]:
        startIndex.add j
      else:
        endIndex.add j

  # Apply margin
  if startM > 0:
    for i in startIndex:
      for k in max(i - startM, 0) ..< i:
        arr[k] = true

  if startM < 0:
    for i in startIndex:
      for k in i ..< min(i - startM, arrlen):
        arr[k] = false

  if endM > 0:
    for i in endIndex:
      for k in i ..< min(i + endM, arrlen):
        arr[k] = true

  if endM < 0:
    for i in endIndex:
      for k in max(i + endM, 0) ..< i:
        arr[k] = false


proc editMedia*(args: mainArgs) =
  av_log_set_level(AV_LOG_QUIET)

  var tlV3: v3
  var interner = newStringInterner()
  defer: interner.cleanup()

  if args.progress == BarType.machine and args.output != "-":
    conwrite("Starting")

  if args.input == "" and not stdin.isatty():
    let stdinContent = readAll(stdin)
    tlV3 = readJson(stdinContent, interner)
  else:
    if args.input == "":
      error "You need to give auto-editor an input file."
    let inputExt = splitFile(args.input).ext

    if inputExt in [".v1", ".v3", ".json"]:
      tlV3 = readJson(readFile(args.input), interner)
    else:
      # Make `timeline` from media file
      var container = av.open(args.input)
      var tb = AVRational(num: 30, den: 1)
      if container.video.len > 0:
        tb = makeSaneTimebase(container.video[0].avgRate)

      var chunks: seq[(int64, int64, float64)] = @[]
      let src = initMediaInfo(container.formatContext, args.input)

      let (editMethod, strStream, strThres) = parseEditString(args.edit)

      if editMethod in ["audio", "motion"]:
        var threshold = 0.04
        var stream: int32
        try:
          stream = parseInt(strStream).int32
          if strThres != "":
            threshold = parseFloat(strThres)
        except ValueError as e:
          error e.msg

        let bar = initBar(args.progress)

        let levels = (if editMethod == "audio":
          audio(bar, container, args.input, tb, stream)
          else:
          motion(bar, container, args.input, tb, stream)
        )

        var hasLoud = newSeq[bool](levels.len)
        hasLoud = levels.mapIt(it >= threshold)

        let startMargin = parseTime(args.margin[0], tb.float64)
        let endMargin = parseTime(args.margin[1], tb.float64)
        mutMargin(hasLoud, startMargin, endMargin)
        chunks = chunkify(hasLoud)
      elif editMethod == "none":
        let length = mediaLength(container)
        let tbLength = int64(round(tb.cdouble * length))

        if tbLength > 0:
          chunks.add((0'i64, tbLength, 1.0))
      else:
        error "Unknown edit method"

      tlV3 = toNonLinear(addr args.input, tb, src, chunks)


  let (exportKind, tlName, fcpVersion) = parseExportString(args.`export`)

  case exportKind:
  of "premiere":
    fcp7_write_xml(tlName, args.output, false, tlV3)
  of "resolve-fcp7":
    fcp7_write_xml(tlName, args.output, true, tlV3)
  of "final-cut-pro":
    fcp11_write_xml(tlName, fcpVersion, args.output, false, tlV3)
  of "resolve":
    tlV3.setStreamTo0(interner)
    fcp11_write_xml(tlName, fcpVersion, args.output, true, tlV3)
  of "v1", "v3":
    exportJsonTl(tlV3, exportKind, args.output)
  of "shotcut":
    shotcut_write_mlt(args.output, tlV3)
  else:
    error("Unknown export format")
