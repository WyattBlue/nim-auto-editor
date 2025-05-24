import std/json
from std/math import round

import log
import av
import ffmpeg

proc mediaLength*(inputFile: string): float64 =
  # Get the mediaLength in seconds.

  var container = av.open(inputFile)
  var format_ctx = container.formatContext
  defer: container.close()

  var audioStreamIndex = -1  # Get the first audio stream
  for i in 0..<format_ctx.nb_streams:
    if format_ctx.streams[i].codecpar.codec_type == ffmpeg.AVMEDIA_TYPE_AUDIO:
      audioStreamIndex = int(i)
      break

  if audioStreamIndex != -1:
    let stream = container.streams[audioStreamIndex]
    var durationSeconds: float64

    var time_base: AVRational
    var packet = ffmpeg.av_packet_alloc()
    var biggest_pts: int64

    while ffmpeg.av_read_frame(format_ctx, packet) >= 0:
      if packet.stream_index == audioStreamIndex:
        if packet.pts != ffmpeg.AV_NOPTS_VALUE:
          if packet.pts > biggest_pts:
            biggest_pts = packet.pts

      ffmpeg.av_packet_unref(packet)

    if packet != nil:
      ffmpeg.av_packet_free(addr packet)

    time_base = format_ctx.streams[audioStreamIndex].time_base
    return float64(biggest_pts.cdouble * time_base.cdouble)

  error("No audio stream found")


proc editMedia*(args: mainArgs) =
  let length = mediaLength(args.input)
  let tb = AVRational(num: 30, den: 1)

  let tbLength = int64(round(tb.cdouble * length))

  var tl: JsonNode
  if args.`export` == "v1":
    tl = %* {"version": "1", "source": args.input, "chunks": [0, tbLength, 1]}
  else:
    tl = %* {
      "version": "3",
      "timebase": $tb.num & "/" & $tb.den,
      "background": "#000000",
      "v": [],
      "a": [],
     }

  if args.output == "-":
    echo pretty(tl)
  else:
    writeFile(args.output, pretty(tl))