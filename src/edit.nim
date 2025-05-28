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


type v1* = object
  chunks*: seq[(int64, int64, float64)]
  source*: string

func `%`*(obj: v1): JsonNode =
  var jsonChunks = obj.chunks.mapIt(%[%it[0], %it[1], %it[2]])
  return %* {"version": "1", "source": obj.source, "chunks": jsonChunks}


type Video* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

func `%`*(self: Video): JsonNode =
  return %* {
    "name": "video",
    "src": self.src[],
    "start": self.start,
    "dur": self.dur,
    "offset": self.offset,
    "speed": self.speed,
    "stream": self.stream,
  }

type Audio* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

func `%`*(self: Audio): JsonNode =
  return %* {
    "name": "audio",
    "src": self.src[],
    "start": self.start,
    "dur": self.dur,
    "offset": self.offset,
    "speed": self.speed,
    "volume": 1,
    "stream": self.stream,
  }

type v3* = object
  tb*: AVRational
  background*: string
  sr*: int64
  layout*: string
  res*: (int64, int64)
  v*: seq[seq[Video]]
  a*: seq[seq[Audio]]


func `%`*(self: v3): JsonNode =
  return %* {
    "version": "3",
    "timebase": $self.tb.num & "/" & $self.tb.den,
    "background": self.background,
    "resolution": [self.res[0], self.res[1]],
    "samplerate": self.sr,
    "layout": self.layout,
    "v": self.v,
    "a": self.a,
  }


func toNonLinear(src: ptr string, chunks: seq[(int64, int64, float64)]): v3 =
  var vlayer: seq[Video] = @[]
  var alayer: seq[Audio] = @[]
  var i: int64 = 0
  var start: int64 = 0
  var dur: int64
  var offset: int64

  for chunk in chunks:
    if chunk[2] > 0 and chunk[2] < 99999.0:
      dur = int64(round(float64(chunk[1] - chunk[0]) / chunk[2]))
      if dur == 0:
        continue

      offset = int64(float64(chunk[0]) / chunk[2])

      if not (vlayer.len > 0 and vlayer[^1].start == start):
        vlayer.add(Video(src: src, start: start, dur: dur, offset: offset, speed: chunk[2], stream: 0))
        alayer.add(Audio(src: src, start: start, dur: dur, offset: offset, speed: chunk[2], stream: 0))
      start += dur
      i += 1

  return v3(v: @[vlayer], a: @[alayer])



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
  if args.`export` == "v1":
    var tlObj = v1(chunks: chunks, source: args.input)
    tl = %tlObj
  else:
    var tlV3 = toNonLinear(addr args.input, chunks)
    tlV3.res = (1920, 1080)
    tlV3.sr = 48000
    tlV3.layout = "stereo"
    tlV3.tb = tb
    tlV3.background = "#000000"

    if src.v.len > 0:
      tlV3.res = (src.v[0].width, src.v[0].height)
    if src.a.len > 0:
      tlV3.sr = src.a[0].sampleRate
      tlV3.layout = src.a[0].layout
    tl = %tlV3

  if args.output == "-":
    echo pretty(tl)
  else:
    writeFile(args.output, pretty(tl))