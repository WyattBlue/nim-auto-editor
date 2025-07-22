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
  defer: output.close()

  let (outputStream, encoderCtx) = output.addStream(audioCodec, 48000)
  let encoder = encoderCtx.codec
  if encoder.sample_fmts == nil:
    error &"{encoder.name}: No known audio formats avail."
  let audioFormat = encoder.sample_fmts[0]
  if avcodec_open2(encoderCtx, encoder, nil) < 0:
    error "Could not open encoder"
  defer: avcodec_free_context(addr encoderCtx)

  output.startEncoding()
  conwrite("Generating audio from timeline")

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  let noColor = false
  var title = fmt"({ext[1 .. ^1]}) "
  var barIndex = -1.0
  var encoderTitles: seq[string] = @[]
  if noColor:
    encoderTitles.add audioCodec
  else:
    encoderTitles.add &"\e[32m{audioCodec}"

  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.`end`.float, title)

  # Process audio directly from timeline using the frame iterator
  let frameSize = if encoderCtx.frame_size > 0: encoderCtx.frame_size else: 1024
  for (frame, index) in makeNewAudioFrames(audioFormat, tl, tempDir, frameSize):
    defer: av_frame_free(addr frame)

    if frame.format != encoderCtx.sample_fmt.cint:
      error "Frame format doesn't match encoder format"

    if avcodec_send_frame(encoderCtx, frame) >= 0:
      while avcodec_receive_packet(encoderCtx, outPacket) >= 0:
        barIndex = -1.0
        outPacket.stream_index = outputStream.index
        av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)

        var time = frame.time(outputStream.time_base)
        if time != -1.0:
          barIndex = round(time * tl.tb)
        output.mux(outPacket[])
        av_packet_unref(outPacket)

        if barIndex != -1.0:
          bar.tick(barIndex)

  bar.`end`()

  # Flush streams
  if avcodec_send_frame(encoderCtx, nil) >= 0:
    while avcodec_receive_packet(encoderCtx, outPacket) >= 0:
      outPacket.stream_index = outputStream.index
      av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)
      output.mux(outPacket[])
      av_packet_unref(outPacket)
