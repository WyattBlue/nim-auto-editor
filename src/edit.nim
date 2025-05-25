import std/json
import std/sequtils
from std/math import round

import log
import av
import media
import ffmpeg

proc mediaLength*(container: InputContainer): float64 =
  # Get the mediaLength in seconds.

  var format_ctx = container.formatContext
  defer: container.close()

  var audioStreamIndex = -1  # Get the first audio stream
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
        if packet.pts != ffmpeg.AV_NOPTS_VALUE:
          if packet.pts > biggest_pts:
            biggest_pts = packet.pts

      ffmpeg.av_packet_unref(packet)

    if packet != nil:
      ffmpeg.av_packet_free(addr packet)

    time_base = format_ctx.streams[audioStreamIndex].time_base
    return float64(biggest_pts.cdouble * time_base.cdouble)

  error("No audio stream found")


# type VSpace = object
#   name: string

# type v3 = object
#   tb: AVRational
#   background: string
#   v: seq[]
#   a: seq[]

proc editMedia*(args: mainArgs) =
  var container = av.open(args.input)

  let tb = AVRational(num: 30, den: 1)

  # Get the timeline resolution from the first video stream.
  var tlWidth = 1920
  var tlHeight = 1080
  var tlSampleRate = 48000
  var tlLayout = "stereo"
  let src = initMediaInfo(container.formatContext, args.input)
  if src.v.len > 0:
    tlWidth = src.v[0].width
    tlHeight = src.v[0].height
  if src.a.len > 0:
    tlSampleRate = src.a[0].sampleRate
    tlLayout = src.a[0].layout

  let length = mediaLength(container)
  let tbLength = int64(round(tb.cdouble * length))

  var chunks: seq[(int64, int64, float64)]
  if tbLength > 0:
    chunks.add((0'i64, tbLength, 1.0))

  var tl: JsonNode
  if args.`export` == "v1":
    var jsonChunks = chunks.mapIt(%[%it[0], %it[1], %it[2]])

    tl = %* {"version": "1", "source": args.input, "chunks": jsonChunks}
  else:

    var jsonVlayer: JsonNode = %[ %* {
      "name": "video",
      "src": args.input,
      "start": 0,
      "dur": tbLength,
      "offset": 0,
      "speed": 1.0,
      "stream": 0,
    }]

    var jsonAlayer: JsonNode = %[ %* {
      "name": "audio",
      "src": args.input,
      "start": 0,
      "dur": tbLength,
      "offset": 0,
      "speed": 1.0,
      "stream": 0,
    }]

    tl = %* {
      "version": "3",
      "timebase": $tb.num & "/" & $tb.den,
      "background": "#000000",
      "resolution": [tlWidth, tlHeight],
      "samplerate": tlSampleRate,
      "layout": tlLayout,
      "v": [jsonVlayer],
      "a": [jsonAlayer],
     }

  if args.output == "-":
    echo pretty(tl)
  else:
    writeFile(args.output, pretty(tl))