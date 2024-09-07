import ffmpeg
import std/strformat
import std/math

type
  VideoStream* = ref object
    duration*: float = 0.0
    bitrate*: int64 = 0
    codec*: string
    lang*: string
    width*: cint
    height*: cint
    avg_rate*: AVRational
    timebase*: string
    # dar*: Rational[int] = 0//1
    sar*: string
    pix_fmt*: string
    color_range*: int
    color_space*: int
    color_primaries*: int
    color_trc*: int

  AudioStream* = ref object
    duration*: float
    bitrate*: int64
    codec*: string
    lang*: string
    sampleRate*: cint
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
    duration*: float
    bitrate*: int64
    recommendedTimebase*: string
    v*: seq[VideoStream]
    a*: seq[AudioStream]
    s*: seq[SubtitleStream]
    d*: seq[DataStream]

func fracToHuman(a: AVRational): string =
  if a.den == 1:
    return fmt"{a.num}"
  else:
    return fmt"{a.num}/{a.den}"

proc round(x: AVRational, places: int): float =
  round(x.num.float / x.den.float, places)

proc make_sane_timebase(fps: AVRational): string =
  let tb = round(fps, 2)

  let ntsc_60 = AVRational(num: 60000, den: 1001)
  let ntsc = AVRational(num: 30000, den: 1001)
  let film_ntsc = AVRational(num: 24000, den: 1001)

  if tb == round(ntsc_60, 2):
    return $ntsc_60.num & "/" & $ntsc_60.den
  if tb == round(ntsc, 2):
    return $ntsc.num & "/" & $ntsc.den
  if tb == round(film_ntsc, 2):
    return $film_ntsc.num & "/" & $film_ntsc.den

  return $fps.num & "/" & $fps.den

proc initMediaInfo(formatContext: ptr AVFormatContext, path: string): MediaInfo =
  result.path = path
  result.duration = float(formatContext.duration) / AV_TIME_BASE
  result.bitrate = formatContext.bit_rate
  result.v = @[]
  result.a = @[]
  result.s = @[]
  result.d = @[]

  var lang: string
  for i in 0 ..< formatContext.nb_streams.int:
    let stream = formatContext.streams[i]
    let codecParameters = stream.codecpar
    var codecContext = avcodec_alloc_context3(nil)
    discard avcodec_parameters_to_context(codecContext, codecParameters)

    var entry = av_dict_get(cast[ptr AVDictionary](stream.metadata), "language", nil, 0)
    if entry != nil:
      lang = $entry.value
    else:
      lang = "und"

    if codecParameters.codec_type == AVMEDIA_TYPE_VIDEO:
      result.v.add(VideoStream(
        duration: float(stream.duration) * av_q2d(stream.time_base),
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
        width: codecContext.width,
        height: codecContext.height,
        avg_rate: stream.avg_frame_rate,
        timebase: fmt"{stream.time_base.num}/{stream.time_base.den}",
        sar: fmt"{codecContext.sample_aspect_ratio.num}:{codecContext.sample_aspect_ratio.den}",
        pix_fmt: $av_get_pix_fmt_name(codecContext.pix_fmt),
        color_range: codecContext.color_range.int,
        color_space: codecContext.colorspace.int,
        color_primaries: codecContext.color_primaries.int,
        color_trc: codecContext.color_trc.int,
      ))
    elif codecParameters.codec_type == AVMEDIA_TYPE_AUDIO:
      var layout: array[64, char]
      discard av_channel_layout_describe(addr codecContext.ch_layout, cast[cstring](addr layout[0]), sizeof(layout).csize_t)

      result.a.add(AudioStream(
        duration: float(stream.duration) * av_q2d(stream.time_base),
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
        sampleRate: codecContext.sample_rate,
        layout: $cast[cstring](addr layout[0]),
      ))
    elif codecParameters.codec_type == AVMEDIA_TYPE_SUBTITLE:
      result.s.add(SubtitleStream(
        duration: float(stream.duration) * av_q2d(stream.time_base),
        bitrate: codecContext.bit_rate,
        codec: $avcodec_get_name(codecContext.codec_id),
        lang: lang,
      ))

    avcodec_free_context(addr codecContext)

  if result.v.len == 0:
    result.recommendedTimebase = "30/1"
  else:
    result.recommendedTimebase = make_sane_timebase(result.v[0].avg_rate)

export fracToHuman, initMediaInfo