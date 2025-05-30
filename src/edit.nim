import std/json
from std/math import round

import log
import av
import media
import ffmpeg
import timeline
import formats/fcp11

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
  var container = av.open(args.input)

  let tb = AVRational(num: 30, den: 1)

  # Get the timeline resolution from the first video stream.
  let src = initMediaInfo(container.formatContext, args.input)
  let length = mediaLength(container)
  let tbLength = int64(round(tb.cdouble * length))

  var chunks: seq[(int64, int64, float64)]
  if tbLength > 0:
    chunks.add((0'i64, tbLength, 1.0))

  var tl: JsonNode
  var tlV3: v3
  if args.`export` == "v1":
    var tlObj = v1(chunks: chunks, source: args.input)
    tl = %tlObj
  else:
    tlV3 = toNonLinear(addr args.input, chunks)
    tlV3.tb = tb
    tlV3.background = "#000000"
    tlV3.res = src.get_res()
    tlV3.sr = 48000
    tlV3.layout = "stereo"
    if src.a.len > 0:
      tlV3.sr = src.a[0].sampleRate
      tlV3.layout = src.a[0].layout

    tl = %tlV3

  if args.`export` == "final-cut-pro":
    fcp11_write_xml("Auto-Editor Media Group", 11, args.output, false, tlV3)
  elif args.`export` == "v1" or args.`export` == "v3":
    if args.output == "-":
      echo pretty(tl)
    else:
      writeFile(args.output, pretty(tl))
  else:
    error("Unknown export format")
