import ../ffmpeg
import ../av
import ../log
import ../util/color


proc makeSolid(width: cint, height: cint, color: RGBColor): ptr AVFrame =
  let frame: ptr AVFrame = av_frame_alloc()
  if frame == nil:
    return nil

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

  let color = parseColor("skyblue")
  let frame = makeSolid(1920, 1080, color)
  if frame == nil:
    error "Frame is nil"
  defer: av_frame_free(addr frame)

  var output = openWrite(args[0])
  defer: output.close()

  let (stream, encoderCtx) = output.addStream("libx264", 24, width=1920, height=1080)
  let codec = encoderCtx.codec

  # Open encoder and copy encoder parameters to stream
  if avcodec_open2(encoderCtx, codec, nil) < 0:
    error "Could not open encoder"
  if avcodec_parameters_from_context(stream.codecpar, encoderCtx) < 0:
    error "Could not copy encoder parameters to stream"

  output.startEncoding()

  # Allocate packet
  let packet = av_packet_alloc()
  if packet == nil:
    error "Could not allocate packet"
  defer: av_packet_free(addr packet)

  # Generate frames
  for frameNum in 0 ..< 120:
    frame.pts = frameNum.int64

    for packet in encoderCtx.encode(frame, packet):
      packet.stream_index = stream.index
      av_packet_rescale_ts(packet, encoderCtx.time_base, stream.time_base)
      output.mux(packet[])
      av_packet_unref(packet)

  # Flush encoder
  for packet in encoderCtx.encode(nil, packet):
    packet.stream_index = stream.index
    av_packet_rescale_ts(packet, encoderCtx.time_base, stream.time_base)
    output.mux(packet[])
    av_packet_unref(packet)
