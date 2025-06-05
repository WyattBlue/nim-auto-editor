import std/os
import std/terminal

from std/math import round

import log
import av
import media
import ffmpeg
import timeline
import exports/[fcp7, fcp11, json, shotcut]
import imports/json

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


proc editMedia*(args: mainArgs) =
  av_log_set_level(AV_LOG_QUIET)

  var tlV3: v3
  var interner = newStringInterner()
  defer: interner.cleanup()

  if args.progress == "machine" and args.output != "-":
    stdout.write("Starting\n")
    stdout.flushFile()

  if args.input == "" and not stdin.isatty():
    let stdinContent = readAll(stdin)
    tlV3 = readJson(stdinContent, interner)
  else:
    let inputExt = splitFile(args.input).ext

    if inputExt in [".v1", ".v3", ".json"]:
      tlV3 = readJson(readFile(args.input), interner)
    else:
      # Make `timeline` from media file
      var container = av.open(args.input)
      var tb = AVRational(num: 30, den: 1)
      if container.video.len > 0:
        tb = makeSaneTimebase(container.video[0].avgRate)

      # Get the timeline resolution from the first video stream.
      let src = initMediaInfo(container.formatContext, args.input)
      let length = mediaLength(container)
      let tbLength = int64(round(tb.cdouble * length))

      var chunks: seq[(int64, int64, float64)]
      if tbLength > 0:
        chunks.add((0'i64, tbLength, 1.0))

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
