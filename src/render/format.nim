import std/os
import std/heapqueue
import std/[strformat, strutils]
from std/math import round

import ../timeline
import ../ffmpeg
import ../log
import ../av
import ../util/bar
import audio
import video

type Priority = object
  index: float64
  frameType: string
  frame: ptr AVFrame
  encoderCtx: ptr AVCodecContext
  outputStream: ptr AVStream

proc `<`(a, b: Priority): bool = a.index < b.index


proc makeMedia*(args: mainArgs, tl: v3, ctr: Container, outputPath: string, bar: Bar) =
  var output = openWrite(outputPath)
  defer: output.close()

  # Setup video
  var videoEncoderCtx: ptr AVCodecContext = nil
  var videoOutputStream: ptr AVStream = nil
  var videoFramesIterator: iterator(): (ptr AVFrame, int) = nil # Changed to match Python
  var videoInputCodec: ptr AVCodec = nil

  if ctr.default_vid notIn {"none", "png"} and tl.v.len > 0:
    var vEncCtx, vOutStream: ptr AVCodecContext
    var vCodec: ptr AVCodec # To hold the actual codec

    # render_av in Python yields (output_stream, video_frame_generator)
    # The Nim makeNewVideoFrames needs to provide the encoder context, stream, and codec.
    # The first yielded item from makeNewVideoFrames is assumed to set up the encoder/stream.
    for (frame, index, encCtx, outStream, codec) in makeNewVideoFrames(output, tl, args):
      videoEncoderCtx = encCtx
      videoOutputStream = outStream
      videoInputCodec = codec # Store the codec
      videoFramesIterator = makeNewVideoFrames(output, tl, args) # Re-initialize for subsequent calls
      heappush(frameQueue, Priority(
        index: index.float64,
        frameType: "video",
        frame: frame,
        encoderCtx: videoEncoderCtx,
        outputStream: videoOutputStream
      ))
      break # Only take the first frame to set up the stream/encoder
    # After the first iteration, we should have videoEncoderCtx and videoOutputStream set

  # Setup audio
  var audioEncoder: ptr AVCodec
  var audioEncoderCtx: ptr AVCodecContext
  var audioStreams: seq[ptr AVStream] = @[]
  var audioGenFrames: seq[iterator(): (ptr AVFrame, int)] = @[]

  try:
    audioEncoder = avcodec_find_encoder_by_name(args.audio_codec)
    if audioEncoder == nil:
      error(&"Could not find audio encoder: {args.audio_codec}")
  except:
    error(&"Error finding audio encoder: {args.audio_codec}")

  if audioEncoder.sample_fmts == nil:
    error(fmt"{args.audio_codec}: No known audio formats avail.")
  let audioFmt = audioEncoder.sample_fmts[0]

  if ctr.default_aud == "none":
    while tl.a.len > 0:
      tl.a.pop() # Clear audio tracks
  elif tl.a.len > 1 and ctr.max_audios == 1:
    # warning("Dropping extra audio streams (container only allows one)")
    while tl.a.len > 1:
      tl.a.pop()

  if tl.a.len > 0:
    # Assuming makeNewAudio returns (seq[AVStream], seq[iterators])
    (audioStreams, audioGenFrames) = makeNewAudio(output, audioFmt, tl, args, log)
    # Get the encoder context from the first audio stream (assuming they all use the same encoder)
    if audioStreams.len > 0:
      audioEncoderCtx = avcodec_alloc_context3(audioEncoder)
      if audioEncoderCtx == nil:
        error("Could not allocate audio encoder context.")
      avcodec_parameters_to_context(audioEncoderCtx, audioStreams[0].codecpar)
      if avcodec_open2(audioEncoderCtx, audioEncoder, nil) < 0:
        error("Could not open audio encoder.")
      defer: avcodec_free_context(addr audioEncoderCtx)
  else:
    audioStreams = @[]
    audioGenFrames = @[iterator(): (ptr AVFrame, int) = yield (nil, 0)] # Empty iterator

  let noColor = false
  var encoderTitles: seq[string] = @[]

  if videoOutputStream != nil:
    let name = videoInputCodec.canonicalName # Use the actual codec name
    encoderTitles.add(if noColor: name else: fmt"\e[95m{name}")
  if audioStreams.len > 0:
    let name = audioEncoder.canonicalName
    encoderTitles.add(if noColor: name else: fmt"\e[96m{name}")

  var title = fmt"({splitFile(outputPath).ext[1 .. ^1]}) "
  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.`end`.float, title)

  const MAX_AUDIO_AHEAD = 30.0 # In timebase, how far audio can be ahead of video.
  const MAX_SUB_AHEAD = 30.0

  # Priority queue for ordered frames by time_base.
  var frameQueue = initHeapQueue[Priority]()
  var latestAudioIndex = -Inf.float64
  var earliestVideoIndex: float64 = -1.0 # Use -1.0 or similar to indicate not yet set

  # Populate initial frames (only video, audio and subtitles will be added dynamically)
  # This part is different from the original Nim code, as frames are now added in the loop
  # based on synchronization logic.

  while true:
    var shouldGetAudio = false

    if earliestVideoIndex < 0: # If video hasn't started or no video stream
      shouldGetAudio = true
    else:
      # Update latest_audio_index and latest_sub_index from existing frames in queue
      # This is slightly less efficient than Python's heap, as Nim's heapqueue doesn't expose
      # direct iteration, so we recompute from current queue
      var currentLatestAudioIndex = -Inf.float64
      for item in frameQueue:
        if item.frameType == "audio":
          currentLatestAudioIndex = max(currentLatestAudioIndex, item.index)
      latestAudioIndex = currentLatestAudioIndex
      shouldGetAudio = latestAudioIndex <= earliestVideoIndex + MAX_AUDIO_AHEAD

    var videoFrame: ptr AVFrame = nil
    var videoIndex = 0
    if videoFramesIterator != nil:
      # Try to get a video frame
      (videoFrame, videoIndex) = videoFramesIterator()
      if videoFrame != nil:
        earliestVideoIndex = videoIndex.float64
        heappush(frameQueue, Priority(
          index: videoIndex.float64,
          frameType: "video",
          frame: videoFrame,
          encoderCtx: videoEncoderCtx,
          outputStream: videoOutputStream
        ))

    var audioFrames: seq[ptr AVFrame] = newSeq[ptr AVFrame](audioGenFrames.len)
    if shouldGetAudio:
      for i, gen in audioGenFrames:
        var audIndex: int
        (audioFrames[i], audIndex) = gen() # Get audio frame from each generator

    # Break if no more frames to process
    if videoFrame == nil and all(f == nil for f in audioFrames) and all(f == nil for f in subFrames):
      break

    if shouldGetAudio:
      for i, aframe in audioFrames:
        if aframe == nil:
          continue
        # Assuming `pts` is a field in AVFrame and `time_base` is available
        # Need to convert audioFrame.pts to a common timebase (tl.tb) for comparison
        let pts = aframe.pts.float64 * (tl.tb.numerator.float64 / tl.tb.denominator.float64) /
                  (audioStreams[i].time_base.num.float64 / audioStreams[i].time_base.den.float64)
        heappush(frameQueue, Priority(
          index: pts,
          frameType: "audio",
          frame: aframe,
          encoderCtx: audioEncoderCtx, # All audio streams use the same encoder ctx in Python
          outputStream: audioStreams[i]
        ))

    # Process frames from queue
    while frameQueue.len > 0:
      let item = frameQueue[0]
      if videoFrame != nil and item.index > earliestVideoIndex.float64:
        break # Don't process frames ahead of the latest video frame

      discard frameQueue.pop() # Remove from heap

      # Encode and mux the frame
      # This part needs careful handling of `AVCodecContext.encode` and `output.mux`
      # based on your `av.nim` bindings.
      # The Python `item.stream.encode(item.frame)` handles the encoding logic.
      # In Nim, you'll need to call `avcodec_send_frame` and `avcodec_receive_packet`.

      if item.frameType == "video":
        if videoEncoderCtx == nil: # Should not happen if video stream was setup
          error("Video encoder context is nil when trying to encode video frame.")
        for packet in videoEncoderCtx.encode(item.frame, output.getOutPacket()):
          packet.stream_index = item.outputStream.index
          av_packet_rescale_ts(packet, videoEncoderCtx.time_base, item.outputStream.time_base)
          output.mux(packet[])
          av_packet_unref(packet)
      elif item.frameType == "audio":
        if audioEncoderCtx == nil: # Should not happen if audio stream was setup
          error("Audio encoder context is nil when trying to encode audio frame.")
        for packet in audioEncoderCtx.encode(item.frame, output.getOutPacket()):
          packet.stream_index = item.outputStream.index
          av_packet_rescale_ts(packet, audioEncoderCtx.time_base, item.outputStream.time_base)
          output.mux(packet[])
          av_packet_unref(packet)

      # Update bar progress
      if item.frame.time != -1.0: # Check if time is valid
        bar.tick(round(item.frame.time(item.outputStream.time_base) * tl.tb.float64))

      # Free the frame after processing
      av_frame_free(addr item.frame)


  # Flush streams
  var outPacket = output.getOutPacket() # Get a packet for flushing

  if videoEncoderCtx != nil:
    for packet in videoEncoderCtx.encode(nil, outPacket): # Encode with nil frame to flush
      packet.stream_index = videoOutputStream.index
      av_packet_rescale_ts(packet, videoEncoderCtx.time_base, videoOutputStream.time_base)
      output.mux(packet[])
      av_packet_unref(packet)

  if audioEncoderCtx != nil:
    for packet in audioEncoderCtx.encode(nil, outPacket): # Encode with nil frame to flush
      packet.stream_index = audioStreams[0].index # Assuming first audio stream
      av_packet_rescale_ts(packet, audioEncoderCtx.time_base, audioStreams[0].time_base)
      output.mux(packet[])
      av_packet_unref(packet)

  bar.`end`()
