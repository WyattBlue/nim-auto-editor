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

type InputContainer* = object
  formatContext*: ptr AVFormatContext
  packet*: ptr AVPacket
  video*: seq[ptr AVStream]
  audio*: seq[ptr AVStream]
  subtitle*: seq[ptr AVStream]
  streams*: seq[ptr AVStream]

proc open*(filename: string): InputContainer =
  result = InputContainer()
  result.packet = av_packet_alloc()

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


iterator demux*(self: InputContainer, index: int): var AVPacket =
  while av_read_frame(self.formatContext, self.packet) >= 0:
    if self.packet.stream_index.int == index:
      yield self.packet[]
    av_packet_unref(self.packet)


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
  if container.packet != nil:
    av_packet_free(addr container.packet)
  avformat_close_input(addr container.formatContext)


type OutputContainer* = object
  file: string
  formatCtx*: ptr AVFormatContext
  packet: ptr AVPacket
  streams: seq[ptr AVStream] = @[]
  started: bool = false

proc openWrite*(file: string): OutputContainer =
  let formatCtx: ptr AVFormatContext = nil
  discard avformat_alloc_output_context2(addr formatCtx, nil, nil, file.cstring)
  if formatCtx == nil:
    error "Could not create output context"

  result.file = file
  result.formatCtx = formatCtx
  result.packet = av_packet_alloc()

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

proc addStreamFromTemplate*(self: var OutputContainer,
    streamT: ptr AVStream): ptr AVStream =
  let format = self.formatCtx

  let ctxT = initDecoder(streamT.codecpar)
  let codec: ptr AVCodec = ctxT.codec
  defer: avcodec_free_context(addr ctxT)

  # Assert that this format supports the requested codec.
  if avformat_query_codec(format.oformat, codec.id, FF_COMPLIANCE_NORMAL) == 0:
    let formatName = if format.oformat.name != nil: $format.oformat.name else: "unknown"
    let codecName = if codec.name != nil: $codec.name else: "unknown"
    error &"Format '{formatName}' does not support codec '{codecName}'"

  let stream: ptr AVStream = avformat_new_stream(format, codec)
  self.streams.add stream
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

  return stream

proc addStream*(self: var OutputContainer, codecName: string, rate: cint, width: cint = 640, height: cint = 480): (
    ptr AVStream, ptr AVCodecContext) =
  let codec = initCodec(codecName)
  let format = self.formatCtx

  # Assert that this format supports the requested codec.
  if avformat_query_codec(format.oformat, codec.id, FF_COMPLIANCE_NORMAL) == 0:
    let formatName = if format.oformat.name != nil: $format.oformat.name else: "unknown"
    error &"Format '{formatName}' does not support codec '{codecName}'"

  let stream: ptr AVStream = avformat_new_stream(format, codec)
  if stream == nil:
    error "Could not allocate new stream"
  self.streams.add stream
  let ctx: ptr AVCodecContext = avcodec_alloc_context3(codec)
  if ctx == nil:
    error "Could not allocate encoder context"

  # Now lets set some more sane video defaults
  if codec.`type` == AVMEDIA_TYPE_VIDEO:
    ctx.pix_fmt = AV_PIX_FMT_YUV420P
    ctx.width = width
    ctx.height = height
    ctx.bit_rate = 1000000  # 1 Mbps default bitrate
    ctx.bit_rate_tolerance = 128000
    ctx.framerate = AVRational(num: rate, den: 1)
    ctx.time_base = AVRational(num: 1, den: rate)
    stream.avg_frame_rate = ctx.framerate
    stream.time_base = ctx.time_base
  # Some sane audio defaults
  elif codec.`type` == AVMEDIA_TYPE_AUDIO:
    ctx.sample_fmt = codec.sample_fmts[0]
    ctx.bit_rate = 0
    ctx.bit_rate_tolerance = 32000
    ctx.sample_rate = rate
    stream.time_base = ctx.time_base
    av_channel_layout_default(addr ctx.ch_layout, 2)

  # Some formats want stream headers to be separate
  if (format.oformat.flags and AVFMT_GLOBALHEADER) != 0:
    ctx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER

  # Initialise stream codec parameters to populate the codec type. Subsequent changes to
  # the codec context will be applied just before encoding starts in `startEncoding()`.
  if avcodec_parameters_from_context(stream.codecpar, ctx) < 0:
    error "Could not set ctx parameters"

  return (stream, ctx)

proc startEncoding*(self: var OutputContainer) =
  if self.started:
    return

  self.started = true
  let outputCtx = self.formatCtx
  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    var ret = avio_open(addr outputCtx.pb, self.file.cstring, AVIO_FLAG_WRITE)
    if ret < 0:
      error fmt"Could not open output file '{self.file}'"

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"


proc mux*(self: var OutputContainer, packet: var AVPacket) =
  self.startEncoding()

  if packet.stream_index < 0 or cuint(packet.stream_index) >= self.formatCtx.nb_streams:
    error "Bad packet stream_index"

  let stream: ptr AVStream = self.streams[int(packet.stream_index)]

  # Rebase packet time
  let dst = stream.time_base
  if packet.time_base == 0:
    packet.time_base = dst
  elif packet.time_base == dst:
    discard
  else:
    av_packet_rescale_ts(addr packet, packet.time_base, dst)

  # Make another reference to the packet, as `av_interleaved_write_frame()`
  # takes ownership of the reference.
  if av_packet_ref(self.packet, addr packet) < 0:
    error "Failed to reference packet"
  if av_interleaved_write_frame(self.formatCtx, self.packet) < 0:
    error "Failed to write packet"


proc close*(outputCtx: ptr AVFormatContext) =
  discard av_write_trailer(outputCtx)

  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    discard avio_closep(addr outputCtx.pb)
  avformat_free_context(outputCtx)

proc close*(self: OutputContainer) =
  if self.packet != nil:
    av_packet_free(addr self.packet)
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


func canonicalName*(codec: ptr AVCodec): string =
  return $avcodec_get_name(codec.id)

func time*(frame: ptr AVFrame, tb: AVRational): float64 =
  # `tb` should be AVStream.time_base
  if frame.pts == AV_NOPTS_VALUE:
    return -1.0
  return float(frame.pts) * float(tb.num) / float(tb.den)


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
