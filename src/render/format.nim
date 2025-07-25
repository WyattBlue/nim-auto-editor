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
  debug &"Audio stream created with index: {audioOutputStream.index}"
  let audioEncoder = audioEncoderCtx.codec
  if audioEncoder.sample_fmts == nil:
    error &"{audioEncoder.name}: No known audio formats avail."
  let audioFormat = audioEncoder.sample_fmts[0]
  if avcodec_open2(audioEncoderCtx, audioEncoder, nil) < 0:
    error "Could not open audio encoder"
  defer: avcodec_free_context(addr audioEncoderCtx)

  # Setup video stream if needed
  var videoOutputStream: ptr AVStream = nil
  var videoEncoderCtx: ptr AVCodecContext = nil
  var hasVideo = false
  
  if args.videoCodec != "none" and tl.v.len > 0:
    debug &"Setting up video with codec: {args.videoCodec}"
    hasVideo = true
  defer:
    if videoEncoderCtx != nil:
      avcodec_free_context(addr videoEncoderCtx)

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  output.startEncoding()
  conwrite("Generating media from timeline")

  let noColor = false
  var title = fmt"({ext[1 .. ^1]}) "
  var encoderTitles: seq[string] = @[]

  let audioName = audioEncoder.canonicalName
  encoderTitles.add (if noColor: audioName else: &"\e[32m{audioName}")
  
  # Add video name to titles if video was set up
  if videoEncoderCtx != nil:
    let videoName = avcodec_get_name(videoOutputStream.codecpar.codec_id)
    if videoName != nil:
      encoderTitles.add (if noColor: $videoName else: &"\e[95m{$videoName}")

  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.`end`.float, title)

  # Priority queue for ordered frames by timestamp
  var frameQueue = initHeapQueue[Priority]()
  
  const MAX_AUDIO_AHEAD = 30
  var latestAudioIndex = -1000000.0
  var earliestVideoIndex: int = 0
  
  # Populate audio frames first
  let frameSize = if audioEncoderCtx.frame_size > 0: audioEncoderCtx.frame_size else: 1024
  for (audioFrame, audioIndex) in makeNewAudioFrames(audioFormat, tl, tempDir, frameSize):
    debug &"audio  index={audioIndex}"
    let clonedAudioFrame = av_frame_clone(audioFrame)
    if clonedAudioFrame == nil:
      error "Failed to clone audio frame"

    frameQueue.push(Priority(
      index: audioIndex.float64,
      frameType: "audio",
      frame: clonedAudioFrame,
      encoderCtx: audioEncoderCtx,
      outputStream: audioOutputStream
    ))

  # Populate video frames if we have video
  if hasVideo:
    for (videoFrame, videoIndex, vEncoderCtx, vOutputStream) in makeNewVideoFrames(output, tl, args):
      if videoEncoderCtx == nil:
        # First video frame - setup encoder context and stream
        videoEncoderCtx = vEncoderCtx
        videoOutputStream = vOutputStream
        debug &"Video stream setup with index: {videoOutputStream.index}"
      
      debug &"video  index={videoIndex}"
      let clonedVideoFrame = av_frame_clone(videoFrame)
      if clonedVideoFrame == nil:
        error "Failed to clone video frame"
      
      frameQueue.push(Priority(
        index: videoIndex.float64,
        frameType: "video",
        frame: clonedVideoFrame,
        encoderCtx: videoEncoderCtx,
        outputStream: videoOutputStream
      ))

  # Process frames from queue in timestamp order
  debug &"Processing {frameQueue.len} frames from priority queue"
  while frameQueue.len > 0:
    let currentFrame = frameQueue.pop()
    debug &"Processing {currentFrame.frameType} frame at index {currentFrame.index}"
    
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
