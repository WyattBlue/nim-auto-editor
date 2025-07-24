import ../ffmpeg
import ../av
import ../log
import ../util/color
import std/math


proc makeSolid(width: cint, height: cint, color: RGBColor): ptr AVFrame =
  let frame: ptr AVFrame = av_frame_alloc()
  if frame == nil:
    return nil

  # Use YUV420P format for better H.264 compatibility
  frame.format = AV_PIX_FMT_YUV420P.cint
  frame.width = width
  frame.height = height

  if av_frame_get_buffer(frame, 32) < 0:
    error "Bad buffer"

  if av_frame_make_writable(frame) < 0:
    error "Can't make frame writable"

  # Fill Y plane (luma)
  let yData: ptr uint8 = frame.data[0]
  let yLinesize: cint = frame.linesize[0]
  # Convert RGB to Y (luma): Y = 0.299*R + 0.587*G + 0.114*B
  let yValue = uint8(0.299 * color.red.float + 0.587 * color.green.float + 0.114 * color.blue.float)

  for y in 0 ..< height:
    let row: ptr uint8 = cast[ptr uint8](cast[int](yData) + y.int * yLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< width:
      rowArray[x] = yValue

  # Fill U plane (chroma)
  let uData: ptr uint8 = frame.data[1]
  let uLinesize: cint = frame.linesize[1]
  # Convert RGB to U: U = -0.169*R - 0.331*G + 0.5*B + 128
  let uValue = uint8(max(0.0, min(255.0, -0.169 * color.red.float - 0.331 * color.green.float + 0.5 * color.blue.float + 128)))

  for y in 0 ..< (height div 2):
    let row: ptr uint8 = cast[ptr uint8](cast[int](uData) + y.int * uLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< (width div 2):
      rowArray[x] = uValue

  # Fill V plane (chroma)
  let vData: ptr uint8 = frame.data[2]
  let vLinesize: cint = frame.linesize[2]
  # Convert RGB to V: V = 0.5*R - 0.419*G - 0.081*B + 128
  let vValue = uint8(max(0.0, min(255.0, 0.5 * color.red.float - 0.419 * color.green.float - 0.081 * color.blue.float + 128)))

  for y in 0 ..< (height div 2):
    let row: ptr uint8 = cast[ptr uint8](cast[int](vData) + y.int * vLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< (width div 2):
      rowArray[x] = vValue

  return frame

proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Experimental stuff"
    quit(0)

  av_log_set_level(AV_LOG_QUIET)

  let color = RGBColor(red: 0, green: 100, blue: 255)
  let frame = makeSolid(1920, 1080, color)
  if frame == nil:
    error "Frame is nil"
  defer: av_frame_free(addr frame)

  # Create output container
  var formatCtx: ptr AVFormatContext = nil
  discard avformat_alloc_output_context2(addr formatCtx, nil, nil, args[0].cstring)
  if formatCtx == nil:
    error "Could not create output context"
  defer: avformat_free_context(formatCtx)

  # Find H.264 encoder
  let codec = avcodec_find_encoder_by_name("libx264")
  if codec == nil:
    error "H.264 encoder not found"

  # Create video stream
  let stream = avformat_new_stream(formatCtx, codec)
  if stream == nil:
    error "Could not create video stream"
  
  # Create encoder context
  let encoderCtx = avcodec_alloc_context3(codec)
  if encoderCtx == nil:
    error "Could not allocate encoder context"
  defer: avcodec_free_context(addr encoderCtx)

  # Set encoder parameters
  encoderCtx.width = 1920
  encoderCtx.height = 1080
  encoderCtx.time_base = AVRational(num: 1, den: 24)
  encoderCtx.framerate = AVRational(num: 24, den: 1)
  encoderCtx.pix_fmt = AV_PIX_FMT_YUV420P
  encoderCtx.bit_rate = 0

  # Set global header flag if needed
  if (formatCtx.oformat.flags and AVFMT_GLOBALHEADER) != 0:
    encoderCtx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER

  # Set stream parameters
  stream.time_base = encoderCtx.time_base

  # Set encoder options for H.264
  var opt: ptr AVDictionary = nil
  discard av_dict_set(addr opt, "preset", "ultrafast", 0)
  discard av_dict_set(addr opt, "profile", "baseline", 0)
  defer: av_dict_free(addr opt)

  # Open encoder
  if avcodec_open2(encoderCtx, codec, addr opt) < 0:
    error "Could not open encoder"

  # Copy encoder parameters to stream
  if avcodec_parameters_from_context(stream.codecpar, encoderCtx) < 0:
    error "Could not copy encoder parameters to stream"

  # Open output file
  if (formatCtx.oformat.flags and AVFMT_NOFILE) == 0:
    if avio_open(addr formatCtx.pb, args[0].cstring, AVIO_FLAG_WRITE) < 0:
      error "Could not open output file"

  # Write header
  if avformat_write_header(formatCtx, nil) < 0:
    error "Error writing header"

  # Allocate packet
  let packet = av_packet_alloc()
  if packet == nil:
    error "Could not allocate packet"
  defer: av_packet_free(addr packet)

  # Generate frames
  for frameNum in 0 ..< 120:
    frame.pts = frameNum.int64

    if avcodec_send_frame(encoderCtx, frame) < 0:
      error "Error sending frame to encoder"

    # Receive encoded packets
    while true:
      let receiveRet = avcodec_receive_packet(encoderCtx, packet)
      if receiveRet == AVERROR_EAGAIN or receiveRet == AVERROR_EOF:
        break
      elif receiveRet < 0:
        error "Error receiving packet from encoder"

      packet.stream_index = stream.index
      av_packet_rescale_ts(packet, encoderCtx.time_base, stream.time_base)
      
      # Write packet
      if av_interleaved_write_frame(formatCtx, packet) < 0:
        error "Error writing packet"
        
      av_packet_unref(packet)

  # Flush encoder
  discard avcodec_send_frame(encoderCtx, nil)
  while true:
    let receiveRet = avcodec_receive_packet(encoderCtx, packet)
    if receiveRet == AVERROR_EAGAIN or receiveRet == AVERROR_EOF:
      break
    elif receiveRet < 0:
      break

    packet.stream_index = stream.index
    av_packet_rescale_ts(packet, encoderCtx.time_base, stream.time_base)
    
    if av_interleaved_write_frame(formatCtx, packet) < 0:
      error "Error writing packet"
      
    av_packet_unref(packet)

  # Write trailer
  discard av_write_trailer(formatCtx)

  # Close output file
  if (formatCtx.oformat.flags and AVFMT_NOFILE) == 0:
    discard avio_closep(addr formatCtx.pb)
