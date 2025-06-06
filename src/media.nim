import std/strformat
import std/hashes

import av
import ffmpeg

type
  VideoStream* = ref object
    duration*: float64 = 0.0
    bitrate*: int64 = 0
    codec*: string
    lang*: string
    width*: cint
    height*: cint
    avg_rate*: AVRational
    timebase*: string
    sar*: string
    pix_fmt*: string

    color_range*: cint
    color_space*: cint
    color_primaries*: cint
    color_transfer*: cint

  AudioStream* = ref object
    duration*: float64
    bitrate*: int64
    codec*: string
    lang*: string
    sampleRate*: cint
    channels*: cint
    layout*: string

  SubtitleStream* = ref object
    duration*: float
    bitrate*: int64
    codec*: string
    lang*: string

  DataStream* = ref object
    duration*: float = 0.0
    bitrate*: int64 = 0
    codec*: string
    lang*: string = ""

  MediaInfo* = object
    path*: string
    duration*: float64
    bitrate*: int64
    recommendedTimebase*: string
    v*: seq[VideoStream]
    a*: seq[AudioStream]
    s*: seq[SubtitleStream]
    d*: seq[DataStream]


proc hash*(mi: MediaInfo): Hash =
  hash(mi.path)

proc `==`*(a, b: MediaInfo): bool =
  a.path == b.path

func get_res*(self: MediaInfo): (int64, int64) =
  if self.v.len > 0:
    return (self.v[0].width, self.v[0].height)
  else:
    return (1920, 1080)


proc initMediaInfo*(formatContext: ptr AVFormatContext,
    path: string): MediaInfo =
  result.path = path
  result.v = @[]
  result.a = @[]
  result.s = @[]
  result.d = @[]

  result.bitrate = formatContext.bit_rate
  if formatContext.duration != AV_NOPTS_VALUE:
    result.duration = float64(formatContext.duration) / AV_TIME_BASE
  else:
    result.duration = 0.0

  var lang: string
  for i in 0 ..< formatContext.nb_streams.int:
    let stream = formatContext.streams[i]
    let codecParameters = stream.codecpar
    var codecContext = avcodec_alloc_context3(nil)
    discard avcodec_parameters_to_context(codecContext, codecParameters)

    var entry = av_dict_get(cast[ptr AVDictionary](stream.metadata), "language",
        nil, 0)
    if entry != nil:
      lang = $entry.value
    else:
      lang = "und"

    var duration: float64
    if stream.duration == AV_NOPTS_VALUE:
      duration = 0.0
    else:
      duration = stream.duration.float64 * av_q2d(stream.time_base)

    if codecParameters.codec_type == AVMEDIA_TYPE_VIDEO:
      result.v.add(VideoStream(
        duration: duration,
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
        width: codecContext.width,
        height: codecContext.height,
        avg_rate: stream.avg_frame_rate,
        timebase: fmt"{stream.time_base.num}/{stream.time_base.den}",
        sar: fmt"{codecContext.sample_aspect_ratio.num}:{codecContext.sample_aspect_ratio.den}",
        pix_fmt: $av_get_pix_fmt_name(codecContext.pix_fmt),
        color_range: codecContext.color_range,
        color_space: codecContext.colorspace,
        color_primaries: codecContext.color_primaries,
        color_transfer: codecContext.color_trc,
      ))
    elif codecParameters.codec_type == AVMEDIA_TYPE_AUDIO:
      var layout: array[64, char]
      discard av_channel_layout_describe(addr codecContext.ch_layout, cast[
          cstring](addr layout[0]), sizeof(layout).csize_t)

      result.a.add(AudioStream(
        duration: duration,
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
        sampleRate: codecContext.sample_rate,
        layout: $cast[cstring](addr layout[0]),
        channels: codecParameters.ch_layout.nb_channels,
      ))
    elif codecParameters.codec_type == AVMEDIA_TYPE_SUBTITLE:
      result.s.add(SubtitleStream(
        duration: duration,
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
      ))

    avcodec_free_context(addr codecContext)


proc initMediaInfo*(path: string): MediaInfo =
  let container = av.open(path)
  result = initMediaInfo(container.formatContext, path)
  container.close()
