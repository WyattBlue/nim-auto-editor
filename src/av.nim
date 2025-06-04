import ffmpeg
import log

proc initDecoder*(codecpar: ptr AVCodecParameters): ptr AVCodecContext =
  let codec: ptr AVCodec = avcodec_find_decoder(codecpar.codec_id)
  if codec == nil:
    error "Decoder not found"

  result = avcodec_alloc_context3(codec)
  if result == nil:
    error "Could not allocate decoder ctx"

  discard avcodec_parameters_to_context(result, codecpar)
  if avcodec_open2(result, codec, nil) < 0:
    error "Could not open codec"

type
  InputContainer* = ref object
    formatContext*: ptr AVFormatContext
    video*: seq[ptr AVStream]
    audio*: seq[ptr AVStream]
    subtitle*: seq[ptr AVStream]
    streams*: seq[ptr AVStream]

proc open*(filename: string): InputContainer =
  result = InputContainer()

  if avformat_open_input(addr result.formatContext, filename.cstring, nil,
      nil) != 0:
    raise newException(IOError, "Could not open input file: " & filename)

  if avformat_find_stream_info(result.formatContext, nil) < 0:
    avformat_close_input(addr result.formatContext)
    raise newException(IOError, "Could not find stream information")

  for i in 0 ..< result.formatContext.nb_streams.int:
    let stream: ptr AVStream = result.formatContext.streams[i]
    result.streams.add(stream)
    case stream.codecpar.codecType
    of AVMEDIA_TYPE_VIDEO:
      result.video.add(stream)
    of AVMEDIA_TYPE_AUDIO:
      result.audio.add(stream)
    of AVMEDIA_TYPE_SUBTITLE:
      result.subtitle.add(stream)
    else:
      discard

func duration*(container: InputContainer): float64 =
  if container.formatContext.duration != AV_NOPTS_VALUE:
    return float64(container.formatContext.duration) / AV_TIME_BASE
  return 0.0

func bitRate*(container: InputContainer): int64 =
  return container.formatContext.bit_rate

proc close*(container: InputContainer) =
  avformat_close_input(addr container.formatContext)

func avgRate*(stream: ptr AVStream): AVRational =
  return stream.avg_frame_rate

