import ffmpeg

type
  Stream* = ref object
    index*: int
    myPtr*: ptr AVStream
    codecContext*: ptr AVCodecContext
    timeBase*: AVRational
    codecType: AVMediaType

  InputContainer* = ref object
    formatContext*: ptr AVFormatContext
    video*: seq[Stream]
    audio*: seq[Stream]
    subtitle*: seq[Stream]
    streams*: seq[Stream]

proc newStream(streamPtr: ptr AVStream): Stream =
  result = Stream(
    index: streamPtr.index,
    myPtr: streamPtr,
    codecContext: avcodec_alloc_context3(nil),
    timeBase: streamPtr.time_base,
    codecType: streamPtr.codecpar.codec_type,
  )
  discard avcodec_parameters_to_context(result.codecContext, streamPtr.codecpar)

proc open*(filename: string): InputContainer =
  result = InputContainer()

  if avformat_open_input(addr result.formatContext, filename.cstring, nil,
      nil) != 0:
    raise newException(IOError, "Could not open input file: " & filename)

  if avformat_find_stream_info(result.formatContext, nil) < 0:
    avformat_close_input(addr result.formatContext)
    raise newException(IOError, "Could not find stream information")

  for i in 0 ..< result.formatContext.nb_streams.int:
    let stream = newStream(result.formatContext.streams[i])
    result.streams.add(stream)
    case stream.codecType
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
  for stream in container.streams:
    avcodec_free_context(addr stream.codecContext)
  avformat_close_input(addr container.formatContext)


func avgRate*(stream: Stream): AVRational =
  return stream.myPtr.avg_frame_rate

func codecName*(stream: Stream): string =
  $avcodec_get_name(stream.codecContext.codec_id)

