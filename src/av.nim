import ffmpeg
import log

proc initEncoder*(id: AVCodecID): (ptr AVCodec, ptr AVCodecContext) =
  let codec: ptr AVCodec = avcodec_find_encoder(id)
  if codec == nil:
    error "Encoder not found: " & $id

  let encoderCtx = avcodec_alloc_context3(codec)
  if encoderCtx == nil:
    error "Could not allocate encoder context"

  return (codec, encoderCtx)

proc initEncoder*(name: string): (ptr AVCodec, ptr AVCodecContext) =
  let codec: ptr AVCodec = avcodec_find_encoder_by_name(name.cstring)
  if codec == nil:
    error "Encoder not found: " & name

  let encoderCtx = avcodec_alloc_context3(codec)
  if encoderCtx == nil:
    error "Could not allocate encoder context"

  return (codec, encoderCtx)

proc initDecoder*(codecpar: ptr AVCodecParameters): ptr AVCodecContext =
  let codec: ptr AVCodec = avcodec_find_decoder(codecpar.codec_id)
  if codec == nil:
    error "Decoder not found"

  result = avcodec_alloc_context3(codec)
  if result == nil:
    error "Could not allocate decoder ctx"

  result.thread_count = 0 # Auto-detect CPU cores
  result.thread_type = FF_THREAD_FRAME or FF_THREAD_SLICE

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

proc mediaLength*(container: InputContainer): AVRational =
  # Get the mediaLength in seconds.

  var formatCtx = container.formatContext
  var audioStreamIndex = (if container.audio.len == 0: -1 else: container.audio[0].index)
  var videoStreamIndex = (if container.video.len == 0: -1 else: container.video[0].index)

  if audioStreamIndex != -1:
    var time_base: AVRational
    var packet = ffmpeg.av_packet_alloc()
    var biggest_pts: int64

    while ffmpeg.av_read_frame(formatCtx, packet) >= 0:
      if packet.stream_index == audioStreamIndex:
        if packet.pts != ffmpeg.AV_NOPTS_VALUE and packet.pts > biggest_pts:
          biggest_pts = packet.pts

      ffmpeg.av_packet_unref(packet)

    if packet != nil:
      ffmpeg.av_packet_free(addr packet)

    time_base = formatCtx.streams[audioStreamIndex].time_base
    return biggest_pts * time_base

  if videoStreamIndex != -1:
    var video = container.video[0]
    if video.duration == AV_NOPTS_VALUE or video.time_base == AV_NOPTS_VALUE:
      return AVRational(0)
    else:
      return video.duration * video.time_base

  error "No audio or video stream found"

proc close*(container: InputContainer) =
  avformat_close_input(addr container.formatContext)

func avgRate*(stream: ptr AVStream): AVRational =
  return stream.avg_frame_rate

func dialogue*(assText: string): string =
  let textLen = assText.len
  var
    i: int64 = 0
    curChar: char
    nextChar: char
    commaCount: int8 = 0
    state = false

  while commaCount < 8 and i < textLen:
    if assText[i] == ',':
      commaCount += 1
    i += 1

  while i < textLen:
    curChar = assText[i]
    nextChar = (if i + 1 >= textLen: '\0' else: assText[i + 1])

    if curChar == '\\' and nextChar == 'N':
      result &= "\n"
      i += 2
      continue

    if not state:
      if curChar == '{' and nextChar != '\\':
        state = true
      else:
        result &= curChar
    elif curChar == '}':
      state = false
    i += 1