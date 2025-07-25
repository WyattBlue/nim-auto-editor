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

proc makeMedia*(args: mainArgs, tl: v3, outputPath: string, bar: Bar) =
  if tl.a.len == 0:
    error "No audio tracks found in timeline"

  let (_, _, ext) = splitFile(outputPath)

  var audioCodec = args.audioCodec
  if audioCodec == "auto":
    audioCodec = case ext.toLowerAscii():
      of ".mp3": "libmp3lame"
      of ".wav": "pcm_s16le"
      of ".m4a", ".mp4": "aac"
      of ".ogg": "libvorbis"
      else: "pcm_s16le"

  var output = openWrite(outputPath)
  defer: output.close()

  # Setup audio encoder
  let (audioOutputStream, audioEncoderCtx) = output.addStream(audioCodec, tl.sr)
  let audioEncoder = audioEncoderCtx.codec
  if audioEncoder.sample_fmts == nil:
    error &"{audioEncoder.name}: No known audio formats avail."
  let audioFormat = audioEncoder.sample_fmts[0]
  if avcodec_open2(audioEncoderCtx, audioEncoder, nil) < 0:
    error "Could not open audio encoder"
  defer: avcodec_free_context(addr audioEncoderCtx)

  output.startEncoding()
  conwrite("Generating media from timeline")

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  let noColor = false
  var title = fmt"({ext[1 .. ^1]}) "
  var encoderTitles: seq[string] = @[]

  let audioName = audioEncoder.canonicalName
  encoderTitles.add (if noColor: audioName else: &"\e[32m{audioName}")

  # Setup video encoder context (will be created by makeNewVideoFrames)
  var videoEncoderCtx: ptr AVCodecContext = nil
  var videoOutputStream: ptr AVStream = nil

  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.`end`.float, title)

  # Priority queue for ordered frames by timestamp
  var frameQueue = initHeapQueue[Priority]()
  
  const MAX_AUDIO_AHEAD = 30.0  # How far audio can be ahead of video
  var latestAudioIndex = -1000000.0
  var currentVideoIndex = 0
  var audioIteratorDone = false
  var videoIteratorDone = false

  # Create iterators
  let frameSize = if audioEncoderCtx.frame_size > 0: audioEncoderCtx.frame_size else: 1024
  
  # Populate initial frames
  var audioFramesPending = 0
  for (audioFrame, audioIndex) in makeNewAudioFrames(audioFormat, tl, tempDir, frameSize):
    frameQueue.push(Priority(
      index: audioIndex.float64,
      frameType: "audio",
      frame: audioFrame,
      encoderCtx: audioEncoderCtx,
      outputStream: audioOutputStream
    ))
    audioFramesPending += 1
    if audioFramesPending >= 10:  # Limit initial audio frames
      break

  var videoFramesPending = 0
  debug "Starting video frame iteration"
  for (videoFrame, videoIndex, vEncoderCtx, vOutputStream, vCodec) in makeNewVideoFrames(output, tl, args):
    debug &"Got video frame {videoIndex}, codec: {cast[int](vCodec)}"
    if videoEncoderCtx == nil:
      videoEncoderCtx = vEncoderCtx
      videoOutputStream = vOutputStream
      
      if vCodec == nil:
        error "vCodec is nil in video frame iterator"
      
      let videoName = vCodec.canonicalName
      encoderTitles.add (if noColor: videoName else: &"\e[95m{videoName}")
    
    frameQueue.push(Priority(
      index: videoIndex.float64,
      frameType: "video",
      frame: videoFrame,
      encoderCtx: videoEncoderCtx,
      outputStream: videoOutputStream
    ))
    videoFramesPending += 1
    currentVideoIndex = videoIndex
    if videoFramesPending >= 10:  # Limit initial video frames
      break
  debug &"Video frame iteration done, got {videoFramesPending} frames"

  # Process frames from queue in timestamp order
  while frameQueue.len > 0:
    let currentFrame = frameQueue.pop()
    
    # Check frame format for audio
    if currentFrame.frameType == "audio":
      if currentFrame.frame.format != currentFrame.encoderCtx.sample_fmt.cint:
        error "Frame format doesn't match encoder format"

    # Encode and mux the frame
    for packet in currentFrame.encoderCtx.encode(currentFrame.frame, outPacket):
      packet.stream_index = currentFrame.outputStream.index
      av_packet_rescale_ts(packet, currentFrame.encoderCtx.time_base, currentFrame.outputStream.time_base)

      let time = currentFrame.frame.time(currentFrame.outputStream.time_base)
      if time != -1.0:
        bar.tick(round(time * tl.tb))
      output.mux(packet[])
      av_packet_unref(packet)

    # Free the frame
    av_frame_free(addr currentFrame.frame)

  bar.`end`()

  # Flush encoders
  if audioEncoderCtx != nil:
    for packet in audioEncoderCtx.encode(nil, outPacket):
      packet.stream_index = audioOutputStream.index
      av_packet_rescale_ts(packet, audioEncoderCtx.time_base, audioOutputStream.time_base)
      output.mux(packet[])
      av_packet_unref(packet)

  if videoEncoderCtx != nil:
    for packet in videoEncoderCtx.encode(nil, outPacket):
      packet.stream_index = videoOutputStream.index
      av_packet_rescale_ts(packet, videoEncoderCtx.time_base, videoOutputStream.time_base)
      output.mux(packet[])
      av_packet_unref(packet)
