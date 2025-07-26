import std/os
import std/options
import std/heapqueue
import std/[strformat, strutils]
from std/math import round

import ../timeline
import ../ffmpeg
import ../log
import ../av
import ../util/bar
import video
import audio

type Priority = object
  index: float64
  frameType: AVMediaType
  frame: ptr AVFrame
  stream: ptr AVStream

proc initPriority(index: float64, frame: ptr AVFrame, stream: ptr AVStream): Priority =
  result.index = index
  result.frameType = (if frame.width > 2: AVMEDIA_TYPE_VIDEO else: AVMEDIA_TYPE_AUDIO)
  result.frame = frame
  result.stream = stream

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

  var (aOutStream, aEncCtx) = output.addStream(audioCodec, rate=AVRational(num: tl.sr, den: 1))
  let encoder = aEncCtx.codec
  if encoder.sample_fmts == nil:
    error &"{encoder.name}: No known audio formats avail."
  if avcodec_open2(aEncCtx, encoder, nil) < 0:
    error "Could not open encoder"
  defer: avcodec_free_context(addr aEncCtx)

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  let noColor = false
  var title = fmt"({ext[1 .. ^1]}) "
  var encoderTitles: seq[string] = @[]

  let name = "h264" #encoder.canonicalName
  encoderTitles.add (if noColor: name else: &"\e[32m{name}")

  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.`end`.float, title)

  let (vEncCtx, vOutStream, videoFrameIter) = makeNewVideoFrames(output, tl, args)

  output.startEncoding()

  let frameSize = if aEncCtx.frame_size > 0: aEncCtx.frame_size else: 1024
  let audioFrameIter = makeNewAudioFrames(encoder.sample_fmts[0], tl, frameSize)

  var shouldGetAudio = false
  const MAX_AUDIO_AHEAD = 30  # In timebase, how far audio can be ahead of video.

  # Priority queue for ordered frames by time_base.
  var frameQueue = initHeapQueue[Priority]()
  var earliestVideoIndex = none(int)
  var latestAudioIndex: float64 = -Inf

  var videoFrame: ptr AVFrame
  var audioFrame: ptr AVFrame
  var index: int
  while true:
    if not earliestVideoIndex.isSome:
      shouldGetAudio = true
    else:
      for item in frameQueue:
        if item.frameType == AVMEDIA_TYPE_AUDIO:
          latestAudioIndex = max(latestAudioIndex, item.index.float64)
      shouldGetAudio = (latestAudioIndex <= float(earliestVideoIndex.get() + MAX_AUDIO_AHEAD))

    if finished(videoFrameIter):
      videoFrame = nil
    else:
      (videoFrame, index) = videoFrameIter()

    if videoFrame != nil:
      earliestVideoIndex = some(index)
      frameQueue.push(initPriority(float(index), videoFrame, vOutStream))

    if finished(audioFrameIter):
      audioFrame = nil
    elif shouldGetAudio:
      (audioFrame, _) = audioFrameIter()
      if audioFrame != nil:
        index = int(round(audioFrame.time(aOutStream.time_base) * tl.tb))

    # Break if no more frames
    if audioFrame == nil and videoFrame == nil:
      break

    if shouldGetAudio:
      if audioFrame != nil:
        frameQueue.push(initPriority(float(index), audioFrame, aOutStream))

    while frameQueue.len > 0 and frameQueue[0].index <= float64(index):
      let item = frameQueue.pop()
      let frame = item.frame
      let frameType = item.frameType

      let encCtx = (if frameType == AVMEDIA_TYPE_VIDEO: vEncCtx else: aEncCtx)
      let outputStream = (if frameType == AVMEDIA_TYPE_VIDEO: vOutStream else: aOutStream)

      for outPacket in encCtx.encode(frame, outPacket):
        outPacket.stream_index = outputStream.index
        av_packet_rescale_ts(outPacket, encCtx.time_base, outputStream.time_base)

        let time = frame.time(1 / tl.tb)
        if time != -1.0:
          bar.tick(round(time * tl.tb))
        output.mux(outPacket[])
        av_packet_unref(outPacket)

  bar.`end`()

  # Flush streams
  for outPacket in vEncCtx.encode(nil, outPacket):
    outPacket.stream_index = vOutStream.index
    av_packet_rescale_ts(outPacket, vEncCtx.time_base, vOutStream.time_base)
    output.mux(outPacket[])
    av_packet_unref(outPacket)

  for outPacket in aEncCtx.encode(nil, outPacket):
    outPacket.stream_index = aOutStream.index
    av_packet_rescale_ts(outPacket, aEncCtx.time_base, aOutStream.time_base)
    output.mux(outPacket[])
    av_packet_unref(outPacket)

  output.close()
