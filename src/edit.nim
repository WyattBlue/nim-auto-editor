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


proc editMedia*(args: mainArgs) =
  var tlV3: v3
  var interner = newStringInterner()
  defer: interner.cleanup()

  if not stdin.isatty():
    let stdinContent = readAll(stdin)
    tlV3 = readJson(stdinContent, interner)
  else:
    let inputExt = splitFile(args.input).ext

    if inputExt == ".v3" or inputExt == ".v1":
      tlV3 = readJson(readFile(args.input), interner)
    else:
      # Make `timeline` from media file
      var container = av.open(args.input)
      var tb = AVRational(num: 30, den: 1)

      # Get the timeline resolution from the first video stream.
      let src = initMediaInfo(container.formatContext, args.input)
      let length = mediaLength(container)
      let tbLength = int64(round(tb.cdouble * length))

      var chunks: seq[(int64, int64, float64)]
      if tbLength > 0:
        chunks.add((0'i64, tbLength, 1.0))

      tlV3 = toNonLinear(addr args.input, tb, src, chunks)

  const tlName = "Auto-Editor Media Group"

  if args.`export` == "premiere":
    fcp7_write_xml(tlName, args.output, false, tlV3)
  elif args.`export` == "resolve-fcp7":
    fcp7_write_xml(tlName, args.output, true, tlV3)
  elif args.`export` == "final-cut-pro":
    fcp11_write_xml(tlName, 11, args.output, false, tlV3)
  elif args.`export` == "resolve":
    fcp11_write_xml(tlName, 10, args.output, true, tlV3)
  elif args.`export` == "v1" or args.`export` == "v3":
    export_json_tl(tlV3, args.`export`, args.output)
  elif args.`export` == "shotcut":
    shotcut_write_mlt(args.output, tlV3)
  else:
    error("Unknown export format")
