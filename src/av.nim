import std/strformat

import ffmpeg
import log

proc `|=`*[T](a: var T, b: T) =
  a = a or b

proc initCodec(name: string): ptr AVCodec =
  result = avcodec_find_encoder_by_name(name.cstring)
  if result == nil:
    let desc = avcodec_descriptor_get_by_name(name.cstring)
    if desc != nil:
      result = avcodec_find_encoder(desc.id)
  if result == nil:
    error "Codec not found: " & name

proc initEnCtx(codec: ptr AVCodec): ptr AVCodecContext =
  let encoderCtx = avcodec_alloc_context3(codec)
  if encoderCtx == nil:
    error "Could not allocate encoder context"

  if codec.sample_fmts != nil:
    encoderCtx.sample_fmt = codec.sample_fmts[0]

  return encoderCtx

proc initEncoder*(id: AVCodecID): (ptr AVCodec, ptr AVCodecContext) =
  let codec: ptr AVCodec = avcodec_find_encoder(id)
  if codec == nil:
    error "Encoder not found: " & $id
  return (codec, initEnCtx(codec))

proc initEncoder*(name: string): (ptr AVCodec, ptr AVCodecContext) =
  let codec = initCodec(name)
  return (codec, initEnCtx(codec))

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


proc allocResampler*(decoderCtx: ptr AVCodecContext): ptr SwrContext =
  var swrCtx: ptr SwrContext = swr_alloc()
  if swrCtx == nil:
    error "Could not allocate resampler context"

  if av_opt_set_chlayout(swrCtx, "in_chlayout", addr decoderCtx.ch_layout, 0) < 0:
    error "Could not set input channel layout"

  if av_opt_set_int(swrCtx, "in_sample_rate", decoderCtx.sample_rate, 0) < 0:
    error "Could not set input sample rate"

  if av_opt_set_sample_fmt(swrCtx, "in_sample_fmt", decoderCtx.sample_fmt, 0) < 0:
    error "Could not set input sample format"
  return swrCtx

proc setResampler*(swrCtx: ptr SwrContext, encoderCtx: ptr AVCodecContext): ptr SwrContext =
  if av_opt_set_chlayout(swrCtx, "out_chlayout", addr encoderCtx.ch_layout, 0) < 0:
    error "Could not set output channel layout"

  if av_opt_set_int(swrCtx, "out_sample_rate", encoderCtx.sample_rate, 0) < 0:
    error "Could not set output sample rate"

  if av_opt_set_sample_fmt(swrCtx, "out_sample_fmt", encoderCtx.sample_fmt, 0) < 0:
    error "Could not set output sample format"

  return swrCtx

type InputContainer* = object
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


type OutputContainer* = object
  file: string
  formatCtx*: ptr AVFormatContext


proc defaultVideoCodec*(container: OutputContainer): string =
  # Returns the default video codec this container recommends.
  if container.formatCtx != nil and container.formatCtx.oformat != nil:
    let codecId = container.formatCtx.oformat.video_codec
    if codecId != AV_CODEC_ID_NONE:
      let codecName = avcodec_get_name(codecId)
      if codecName != nil:
        return $codecName
  return ""

proc defaultAudioCodec*(container: OutputContainer): string =
  # Returns the default audio codec this container recommends.
  if container.formatCtx != nil and container.formatCtx.oformat != nil:
    let codecId = container.formatCtx.oformat.audio_codec
    if codecId != AV_CODEC_ID_NONE:
      let codecName = avcodec_get_name(codecId)
      if codecName != nil:
        return $codecName
  return ""

proc defaultSubtitleCodec*(container: OutputContainer): string =
  # Returns the default subtitle codec this container recommends.
  if container.formatCtx != nil and container.formatCtx.oformat != nil:
    let codecId = container.formatCtx.oformat.subtitle_codec
    if codecId != AV_CODEC_ID_NONE:
      let codecName = avcodec_get_name(codecId)
      if codecName != nil:
        return $codecName
  return ""

proc openWrite*(file: string): OutputContainer =
  let formatCtx: ptr AVFormatContext = nil
  discard avformat_alloc_output_context2(addr formatCtx, nil, nil, file.cstring)
  if formatCtx == nil:
    error "Could not create output context"
  OutputContainer(file: file, formatCtx: formatCtx)



proc addStreamFromTemplate*(self: OutputContainer, streamT: ptr AVStream): (ptr AVCodecContext, ptr AVStream) =
  let format = self.formatCtx

  let ctxT = initDecoder(streamT.codecpar)
  let codec: ptr AVCodec = ctxT.codec
  defer: avcodec_free_context(addr ctxT)

  # Assert that this format supports the requested codec.
  if avformat_query_codec(format.oformat[], codec.id, FF_COMPLIANCE_NORMAL) == 0:
    error &"? format does not support ? codec"

  let stream: ptr AVStream = avformat_new_stream(format, codec)
  let ctx: ptr AVCodecContext = avcodec_alloc_context3(codec)

  # Reset the codec tag assuming we are remuxing.
  discard avcodec_parameters_to_context(ctx, streamT.codecpar)
  ctx.codec_tag = 0

  # Some formats want stream headers to be separate
  if (format.oformat.flags and AVFMT_GLOBALHEADER) != 0:
    ctx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER

  # Initialize stream codec parameters to populate the codec type. Subsequent changes to
  # the codec context will be applied just before encoding starts in `start_encoding()`.
  if avcodec_parameters_from_context(stream.codecpar, ctx) < 0:
    error "Could not set ctx parameters"

  return (ctx, stream)

proc addStream*(self: OutputContainer, codecName: string, rate: cint = 48000): (ptr AVCodecContext, ptr AVStream) =
  let codec = initCodec(codecName)
  let format = self.formatCtx

  # Assert that this format supports the requested codec.
  if avformat_query_codec(format.oformat[], codec.id, FF_COMPLIANCE_NORMAL) == 0:
    error &"? format does not support {codecName} codec"

  let stream: ptr AVStream = avformat_new_stream(format, codec)
  if stream == nil:
    error "Could not allocate new stream"
  let ctx: ptr AVCodecContext = avcodec_alloc_context3(codec)
  if ctx == nil:
    error "Could not allocate encoder context"

  # Now lets set some more sane video defaults
  if codec.`type` == AVMEDIA_TYPE_VIDEO:
    # ctx.pix_fmt = AV_PIX_FMT_YUV420P
    ctx.width = 640
    ctx.height = 480
    ctx.bit_rate = 0
    ctx.bit_rate_tolerance = 128000
    # stream.avg_frame_rate = ctx.framerate
    stream.time_base = ctx.time_base
  # Some sane audio defaults
  elif codec.`type` == AVMEDIA_TYPE_AUDIO:
    ctx.sample_fmt = codec.sample_fmts[0]
    ctx.bit_rate = 0
    ctx.bit_rate_tolerance = 32000
    ctx.sample_rate = rate
    stream.time_base = ctx.time_base

  # Some formats want stream headers to be separate
  if (format.oformat.flags and AVFMT_GLOBALHEADER) != 0:
    ctx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER

  # Initialise stream codec parameters to populate the codec type.
  #
  # Subsequent changes to the codec context will be applied just before
  # encoding starts in `start_encoding()`.
  if avcodec_parameters_from_context(stream.codecpar, ctx) < 0:
    error "Could not set ctx parameters"

  return (ctx, stream)

proc startEncoding*(self: OutputContainer) =
  let outputCtx = self.formatCtx
  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    var ret = avio_open(addr outputCtx.pb, self.file.cstring, AVIO_FLAG_WRITE)
    if ret < 0:
      error fmt"Could not open output file '{self.file}'"

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"

proc close*(outputCtx: ptr AVFormatContext) =
  discard av_write_trailer(outputCtx)

  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    discard avio_closep(addr outputCtx.pb)
  avformat_free_context(outputCtx)

proc close*(self: OutputContainer) =
  close(self.formatCtx)

func avgRate*(stream: ptr AVStream): AVRational =
  return stream.avg_frame_rate

func name*(stream: ptr AVStream): string =
  if stream == nil or stream.codecpar == nil:
    return ""

  let codec = avcodec_find_decoder(stream.codecpar.codec_id)
  if codec != nil and codec.name != nil:
    return $codec.name

  # Fallback to codec descriptor if codec not found
  # let desc = avcodec_descriptor_get(stream.codecpar.codec_id)
  # if desc != nil and desc.name != nil:
  #   return $desc.name

  return ""

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
