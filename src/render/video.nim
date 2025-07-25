import std/[sets, tables]
import std/options
import std/strformat
from std/math import round

import ../log
import ../av
import ../ffmpeg
import ../timeline
import ../util/color

# Helps with timing, may be extended.
type VideoFrame = object
  index: int
  src: ptr string

func toInt(r: AVRational): int =
  (r.num div r.den).int

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
  let yValue = uint8(0.299 * color.red.float + 0.587 * color.green.float + 0.114 *
      color.blue.float)

  for y in 0 ..< height:
    let row: ptr uint8 = cast[ptr uint8](cast[int](yData) + y.int * yLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< width:
      rowArray[x] = yValue

  # Fill U plane (chroma)
  let uData: ptr uint8 = frame.data[1]
  let uLinesize: cint = frame.linesize[1]
  # Convert RGB to U: U = -0.169*R - 0.331*G + 0.5*B + 128
  let uValue = uint8(max(0.0, min(255.0, -0.169 * color.red.float - 0.331 *
      color.green.float + 0.5 * color.blue.float + 128)))

  for y in 0 ..< (height div 2):
    let row: ptr uint8 = cast[ptr uint8](cast[int](uData) + y.int * uLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< (width div 2):
      rowArray[x] = uValue

  # Fill V plane (chroma)
  let vData: ptr uint8 = frame.data[2]
  let vLinesize: cint = frame.linesize[2]
  # Convert RGB to V: V = 0.5*R - 0.419*G - 0.081*B + 128
  let vValue = uint8(max(0.0, min(255.0, 0.5 * color.red.float - 0.419 *
      color.green.float - 0.081 * color.blue.float + 128)))

  for y in 0 ..< (height div 2):
    let row: ptr uint8 = cast[ptr uint8](cast[int](vData) + y.int * vLinesize.int)
    let rowArray = cast[ptr UncheckedArray[uint8]](row)
    for x in 0 ..< (width div 2):
      rowArray[x] = vValue

  return frame

iterator makeNewVideoFrames*(output: var OutputContainer, tl: v3, args: mainArgs): (ptr AVFrame, int, ptr AVCodecContext, ptr AVStream) {.closure.} =
  # This iterator follows the Python pattern: first yield sets up the stream and encoder

  var cns = initTable[ptr string, InputContainer]()
  var decoders = initTable[ptr string, ptr AVCodecContext]()
  var seekCost = initTable[ptr string, int]()
  var tous = initTable[ptr string, int]()

  var pix_fmt = AV_PIX_FMT_YUV420P # Reasonable default
  let targetFps = tl.tb # Always constant

  var firstSrc: ptr string = nil
  for src in tl.uniqueSources:
    if firstSrc == nil:
      firstSrc = src

    if src notin cns:
      cns[src] = av.open(src[])
      decoders[src] = initDecoder(cns[src].video[0].codecpar)

  var targetWidth: cint = cint(tl.res[0])
  var targetHeight: cint = cint(tl.res[1])

  if args.scale != 1.0:
    targetWidth = max(cint(round(tl.res[0].float64 * args.scale)), 2)
    targetHeight = max(cint(round(tl.res[1].float64 * args.scale)), 2)

  debug &"Creating video stream with codec: {args.videoCodec}"
  var (outputStream, encoderCtx) = output.addStream(args.videoCodec, rate = targetFps.den,
    width = targetWidth, height = targetHeight)
  let codec = encoderCtx.codec

  outputStream.time_base = av_inv_q(targetFps)
  encoderCtx.framerate = targetFps
  encoderCtx.time_base = av_inv_q(targetFps)
  encoderCtx.thread_type = FF_THREAD_FRAME or FF_THREAD_SLICE

  # Open encoder and copy encoder parameters to stream
  if avcodec_open2(encoderCtx, codec, nil) < 0:
    error "Could not open encoder"
  if avcodec_parameters_from_context(outputStream.codecpar, encoderCtx) < 0:
    error "Could not copy encoder parameters to stream"

  for src, cn in cns:
    if len(cn.video) > 0:
      if args.noSeek:
        seekCost[src] = int(high(uint32) - 1)
        tous[src] = 1000
      else:
        # Keyframes are usually spread out every 5 seconds or less.
        seekCost[src] = toInt(targetFps * AVRational(num: 5, den: 1))
        tous[src] = 1000

      if src == firstSrc and encoderCtx.pix_fmt != AV_PIX_FMT_NONE:
        pix_fmt = encoderCtx.pix_fmt

  debug(&"Clips: {tl.v}")

  var need_valid_fmt = true
  if codec.pix_fmts != nil and codec.pix_fmts[0].cint != 0:
    var i = 0
    while codec.pix_fmts[i].cint != -1:
      if pix_fmt == codec.pix_fmts[i]:
        need_valid_fmt = false
      i += 1

  if need_valid_fmt:
    if codec.canonicalName == "gif":
      pix_fmt = AV_PIX_FMT_RGB8
    elif codec.canonicalName == "prores":
      pix_fmt = AV_PIX_FMT_YUV422P10LE
    else:
      pix_fmt = AV_PIX_FMT_YUV420P

  # First few frames can have an abnormal keyframe count, so never seek there.
  var seekThreshold = 10
  var seekFrame = -1
  var framesSaved = 0

  var nullFrame = makeSolid(targetWidth, targetHeight, args.background)
  var frameIndex = -1
  var frame: ptr AVFrame = nullFrame

  # Process each frame in timeline order like Python version
  for index in 0 ..< tl.`end`:
    var objList: seq[VideoFrame] = @[]

    for layer in tl.v:
      for obj in layer:
        if index >= obj.start and index < (obj.start + obj.dur):
          let i = int(round(float(obj.offset + index - obj.start) * obj.speed))
          objList.add VideoFrame(index: i, src: obj.src)

    if tl.chunks.isSome:
      # When there can be valid gaps in the timeline.
      frame = nullFrame
    # else, use the last frame

    for obj in objList:
      var myStream: ptr AVStream = cns[obj.src].video[0]
      echo frameIndex
      if frameIndex > obj.index:
        debug(&"Seek: {frameIndex} -> 0")
        cns[obj.src].seek(0)

      while frameIndex < obj.index:
        let decoder: ptr AVCodecContext = decoders[obj.src]
        var foundFrame = false
        for decodedFrame in cns[obj.src].decode(0.cint, decoder, frame):
          frameIndex = int(round(decodedFrame.time(AVRational(num: 1, den: 30_000)) * tl.tb.float))
          frame = decodedFrame
          foundFrame = true
          break

        if not foundFrame:
          frame = nullFrame
          break

    frame.pts = index.int64
    frame.time_base = av_inv_q(tl.tb)
    yield (frame, index, encoderCtx, outputStream)

  debug(&"Total frames saved seeking: {framesSaved}")
