import std/os
import std/heapqueue
import std/[strformat, strutils]
from std/math import round

import ../timeline
import ../ffmpeg
import ../log
import ../av
import ../util/bar
import video

type Priority = object
  index: float64
  frameType: string
  frame: ptr AVFrame
  packet: ptr AVPacket
  stream: ptr AVStream

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

  # Process audio directly from timeline using the frame iterator
  #let frameSize = if encoderCtx.frame_size > 0: encoderCtx.frame_size else: 1024

  var lastVidEncCtx: ptr AVCodecContext
  var lastOutputStream: ptr AVStream

  for (frame, index, vEncCtx, outputStream) in makeNewVideoFrames(output, tl, args):
    for outPacket in vEncCtx.encode(frame, outPacket):
      outPacket.stream_index = outputStream.index
      av_packet_rescale_ts(outPacket, vEncCtx.time_base, outputStream.time_base)

      let time = frame.time(1 / tl.tb)
      if time != -1.0:
        bar.tick(round(time * tl.tb))
      output.mux(outPacket[])
      av_packet_unref(outPacket)

    lastVidEncCtx = vEncCtx
    lastOutputStream = outputStream

  bar.`end`()

  # Flush streams
  for outPacket in lastVidEncCtx.encode(nil, outPacket):
    outPacket.stream_index = lastOutputStream.index
    av_packet_rescale_ts(outPacket, lastVidEncCtx.time_base, lastOutputStream.time_base)
    output.mux(outPacket[])
    av_packet_unref(outPacket)

  output.close()
