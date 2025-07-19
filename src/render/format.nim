import std/os
import std/heapqueue
import std/strutils

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

proc makeMedia*(tl: v3, tempDir: string, outputPath: string, bar: Bar) =
  conwrite("Processing media")

  # Check if we have audio to process
  if tl.a.len == 0:
    error "No audio tracks found in timeline"

  # Determine output format and codec based on file extension
  let (_, _, ext) = splitFile(outputPath)
  let audioCodec = case ext.toLowerAscii():
    of ".mp3": "libmp3lame"
    of ".wav": "pcm_s16le"
    of ".m4a", ".mp4": "aac"
    of ".ogg": "libvorbis"
    else: "pcm_s16le"  # Default to WAV

  var output = openWrite(outputPath)
  defer: output.close()

  let (outputStream, encoderCtx) = output.addStream(audioCodec, 48000)
  let encoder = encoderCtx.codec
  if avcodec_open2(encoderCtx, encoder, nil) < 0:
    error "Could not open encoder"
  defer: avcodec_free_context(addr encoderCtx)

  output.startEncoding()
  conwrite("Generating audio from timeline")

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  # Process audio directly from timeline using the frame iterator
  for (frame, index) in makeNewAudioFrames(tl, tempDir, tl.sr.int, 2):
    defer: av_frame_free(addr frame)

    if frame.format != encoderCtx.sample_fmt.cint:
      error "Frame format doesn't match encoder format"

    if avcodec_send_frame(encoderCtx, frame) >= 0:
      while avcodec_receive_packet(encoderCtx, outPacket) >= 0:
        outPacket.stream_index = outputStream.index
        av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)
        output.mux(outPacket[])
        av_packet_unref(outPacket)

  bar.`end`()

  # Flush streams
  if avcodec_send_frame(encoderCtx, nil) >= 0:
    while avcodec_receive_packet(encoderCtx, outPacket) >= 0:
      outPacket.stream_index = outputStream.index
      av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)
      output.mux(outPacket[])
      av_packet_unref(outPacket)
