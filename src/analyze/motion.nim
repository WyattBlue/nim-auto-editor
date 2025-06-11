import std/math
import std/strformat
import std/options

import ../av
import ../log
import ../cache
import ../ffmpeg
import ../util/bar

type
  VideoProcessor* = object
    formatCtx*: ptr AVFormatContext
    codecCtx*: ptr AVCodecContext
    videoIndex*: cint
    width*: cint
    blur*: cint
    tb*: AVRational

iterator motionness*(processor: var VideoProcessor): float32 =
  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  var filteredFrame = av_frame_alloc()

  if packet == nil or frame == nil or filteredFrame == nil:
    error "Could not allocate packet/frame"

  defer:
    av_packet_free(addr packet)
    av_frame_free(addr frame)
    av_frame_free(addr filteredFrame)
    if processor.codecCtx != nil:
      avcodec_free_context(addr processor.codecCtx)

  let originalWidth = processor.codecCtx.width
  let originalHeight = processor.codecCtx.height
  let pixelFormat = processor.codecCtx.pix_fmt

  # Use the target timebase (processor.tb) as the stream timebase for the filter
  # This is more reliable than codecCtx.time_base which might be 0/1
  let timeBase = processor.tb
  let floatTb = float64(timeBase)

  # Get pixel format name for buffer args
  let pixFmtName = av_get_pix_fmt_name(pixelFormat)
  if pixFmtName == nil:
    error fmt"Could not get pixel format name for format: {ord(pixelFormat)}"

  # Initialize filter graph for grayscale conversion and blur
  var filterGraph: ptr AVFilterGraph = avfilter_graph_alloc()
  var bufferSrc: ptr AVFilterContext = nil
  var bufferSink: ptr AVFilterContext = nil

  if filterGraph == nil:
    error "Could not allocate filter graph"

  defer:
    if filterGraph != nil:
      avfilter_graph_free(addr filterGraph)

  # Setup video filter chain: scale -> format=gray -> gblur
  let filterDesc = fmt"scale={processor.width}:-1,format=gray,gblur=sigma={processor.blur}"

  # Create buffer source with proper arguments
  let bufferArgs = fmt"video_size={originalWidth}x{originalHeight}:pix_fmt={pixFmtName}:time_base={timeBase.num}/{timeBase.den}:pixel_aspect=1/1"

  var ret = avfilter_graph_create_filter(addr bufferSrc, avfilter_get_by_name("buffer"),
                                        "in", bufferArgs.cstring, nil, filterGraph)
  if ret < 0:
    error fmt"Cannot create buffer source with args: {bufferArgs}, error code: {ret}"

  # Create buffer sink
  ret = avfilter_graph_create_filter(addr bufferSink, avfilter_get_by_name("buffersink"),
                                    "out", nil, nil, filterGraph)
  if ret < 0:
    error "Cannot create buffer sink"

  # Parse and configure the filter chain
  var inputs = avfilter_inout_alloc()
  var outputs = avfilter_inout_alloc()

  if inputs == nil or outputs == nil:
    error "Could not allocate filter inputs/outputs"

  outputs.name = av_strdup("in")
  outputs.filter_ctx = bufferSrc
  outputs.pad_idx = 0
  outputs.next = nil

  inputs.name = av_strdup("out")
  inputs.filter_ctx = bufferSink
  inputs.pad_idx = 0
  inputs.next = nil

  ret = avfilter_graph_parse_ptr(filterGraph, filterDesc.cstring, addr inputs,
      addr outputs, nil)
  if ret < 0:
    error "Could not parse filter graph"

  ret = avfilter_graph_config(filterGraph, nil)
  if ret < 0:
    error "Could not configure filter graph"

  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)

  var totalPixels: int = 0
  var frameIndex: int = 0
  var prevIndex: int = -1

  var prevFrame: seq[uint8] = @[]
  var currentFrame: seq[uint8] = @[]

  # Main decoding loop
  while av_read_frame(processor.formatCtx, packet) >= 0:
    defer: av_packet_unref(packet)

    if packet.stream_index == processor.videoIndex:
      ret = avcodec_send_packet(processor.codecCtx, packet)
      if ret < 0:
        error "Error sending packet to decoder"

      while ret >= 0:
        ret = avcodec_receive_frame(processor.codecCtx, frame)
        if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
          break
        elif ret < 0:
          error fmt"Error receiving frame from decoder: {ret}"

        if frame.pts == AV_NOPTS_VALUE:
          continue

        # Calculate frame index based on timebase
        # Convert frame PTS to the target timebase and get the frame index
        let frameTime = float64(frame.pts) * floatTb
        frameIndex = int(round(frameTime / floatTb))

        if av_buffersrc_add_frame_flags(bufferSrc, frame, AV_BUFFERSRC_FLAG_KEEP_REF) < 0:
          error "Error adding frame to filter"

        ret = av_buffersink_get_frame(bufferSink, filteredFrame)
        if ret < 0:
          continue

        # Initialize total pixels on first frame
        if totalPixels == 0:
          totalPixels = filteredFrame.width * filteredFrame.height

        # Convert frame data to sequence
        let dataSize = totalPixels
        currentFrame.setLen(dataSize)
        copyMem(addr currentFrame[0], filteredFrame.data[0], dataSize)

        var motionValue: float32 = 0.0
        if prevFrame.len > 0:
          # Calculate motion by comparing with previous frame
          var diffCount: int32 = 0
          for i in 0 ..< totalPixels:
            if prevFrame[i] != currentFrame[i]:
              inc diffCount

          motionValue = float32(diffCount) / float32(totalPixels)

        # Yield motion value for this frame
        yield motionValue

        # Update for next iteration
        prevFrame = currentFrame
        prevIndex = frameIndex

        av_frame_unref(filteredFrame)

  # Flush decoder
  discard avcodec_send_packet(processor.codecCtx, nil)
  while avcodec_receive_frame(processor.codecCtx, frame) >= 0:
    if frame.pts == AV_NOPTS_VALUE:
      continue

    let frameTime = float64(frame.pts) * av_q2d(timeBase)
    frameIndex = int(round(frameTime / av_q2d(processor.tb)))

    ret = av_buffersrc_add_frame_flags(bufferSrc, frame, AV_BUFFERSRC_FLAG_KEEP_REF)
    if ret >= 0:
      ret = av_buffersink_get_frame(bufferSink, filteredFrame)
      if ret >= 0:
        if totalPixels == 0:
          totalPixels = filteredFrame.width * filteredFrame.height

        let dataSize = totalPixels
        currentFrame.setLen(dataSize)
        copyMem(addr currentFrame[0], filteredFrame.data[0], dataSize)

        var motionValue: float32 = 0.0
        if prevFrame.len > 0:
          var diffCount: int = 0
          for i in 0 ..< totalPixels:
            if prevFrame[i] != currentFrame[i]:
              inc diffCount
          motionValue = float32(diffCount) / float32(totalPixels)

        yield motionValue

        prevFrame = currentFrame
        prevIndex = frameIndex
        av_frame_unref(filteredFrame)

proc motion*(bar: Bar, container: InputContainer, path: string, tb: AVRational,
    stream: int32): seq[float32] =
  let cacheData = readCache(path, tb, "motion", stream)
  if cacheData.isSome:
    return cacheData.get()

  if stream < 0 or stream >= container.video.len:
    error fmt"audio: audio stream '{stream}' does not exist."

  let videoStream: ptr AVStream = container.video[stream]

  var processor = VideoProcessor(
    formatCtx: container.formatContext,
    codecCtx: initDecoder(videoStream.codecpar),
    videoIndex: videoStream.index,
    width: 400,
    blur: 9,
    tb: tb,
  )

  var inaccurateDur: float = 1024.0
  if videoStream.duration != AV_NOPTS_VALUE and videoStream.time_base != AV_NOPTS_VALUE:
    inaccurateDur = float(videoStream.duration) * float(videoStream.time_base * tb)
  elif container.duration != 0.0:
    inaccurateDur = container.duration / float(tb)

  bar.start(inaccurateDur, "Analyzing motion")
  var i: float = 0
  for value in processor.motionness():
    result.add value
    bar.tick(i)
    i += 1

  bar.`end`()

  writeCache(result, path, tb, "motion", stream)
