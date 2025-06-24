import std/strformat

import av
import ffmpeg
import log

proc processAndEncodeFrame(
  swrCtx: ptr SwrContext, encoderCtx: ptr AVCodecContext,
      outputCtx: ptr AVFormatContext,
  outputStream: ptr AVStream, frame: ptr AVFrame, convertedFrame: ptr AVFrame,
  currentPts: var int64, inputSamples: cint = 0,
      inputData: ptr ptr uint8 = nil): bool =
  var ret: cint
  let decoderSampleRate = if inputData !=
      nil: encoderCtx.sample_rate else: frame.sample_rate

  # Calculate output frame size
  let delay = swr_get_delay(swrCtx, decoderSampleRate.int64)
  let maxDstNbSamples = cint(inputSamples + delay)

  if maxDstNbSamples <= 0:
    return false

  # Ensure frame is clean before allocating
  av_frame_unref(convertedFrame)
  convertedFrame.format = encoderCtx.sample_fmt.cint
  convertedFrame.ch_layout = encoderCtx.ch_layout
  convertedFrame.sample_rate = encoderCtx.sample_rate
  convertedFrame.nb_samples = maxDstNbSamples

  ret = av_frame_get_buffer(convertedFrame, 0)
  if ret < 0:
    error &"Error allocating converted frame buffer: {ret}"

  let convertedSamples = swr_convert(swrCtx,
                                    cast[ptr ptr uint8](
                                        addr convertedFrame.data[0]),
                                    maxDstNbSamples,
                                    inputData,
                                    inputSamples)
  if convertedSamples <= 0:
    return false

  convertedFrame.nb_samples = convertedSamples
  convertedFrame.pts = currentPts
  currentPts += convertedSamples

  # Encode converted frame
  ret = avcodec_send_frame(encoderCtx, convertedFrame)
  if ret < 0 and ret != AVERROR_EAGAIN:
    error &"Error sending frame to encoder: {ret}"

  # Receive and write encoded packets
  while true:
    var outPacket = av_packet_alloc()
    ret = avcodec_receive_packet(encoderCtx, outPacket)
    if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
      av_packet_free(addr outPacket)
      break
    elif ret < 0:
      av_packet_free(addr outPacket)
      break

    outPacket.stream_index = outputStream.index
    if inputData != nil: # This is from flushing, don't set duration
      av_packet_rescale_ts(outPacket, encoderCtx.time_base,
          outputStream.time_base)
    else: # This is from normal frame processing
      outPacket.duration = convertedSamples
      av_packet_rescale_ts(outPacket, encoderCtx.time_base,
          outputStream.time_base)

    ret = av_interleaved_write_frame(outputCtx, outPacket)
    av_packet_free(addr outPacket)
    if ret < 0:
      echo &"Warning: Error muxing packet: {ret}"

  return true

proc toS16Wav*(inputPath: string, outputPath: string, streamIndex: int64) =
  var ret: cint
  var container: InputContainer
  try:
    container = av.open(inputPath)
  except OSError as e:
    error e.msg
  defer: container.close()

  if streamIndex < 0 or streamIndex >= container.audio.len:
    error "Stream index out of range"

  let inputStream: ptr AVStream = container.audio[streamIndex]
  let audioStreamIdx = inputStream.index
  let decoderCtx = initDecoder(inputStream.codecpar)
  defer: avcodec_free_context(addr decoderCtx)

  let outputCtx: ptr AVFormatContext = nil
  ret = avformat_alloc_output_context2(addr outputCtx, nil, "wav",
      outputPath.cstring)
  if outputCtx == nil:
    error "Could not create output context"
  defer:
    if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
      discard avio_closep(addr outputCtx.pb)
    avformat_free_context(outputCtx)

  let (encoder, encoderCtx) = initEncoder("pcm_s16le")
  encoderCtx.sample_rate = decoderCtx.sample_rate
  encoderCtx.ch_layout = decoderCtx.ch_layout
  encoderCtx.bit_rate = 0
  encoderCtx.time_base = AVRational(num: 1, den: decoderCtx.sample_rate)
  if avcodec_open2(encoderCtx, encoder, nil) < 0:
    error "Could not open encoder"
  defer: avcodec_free_context(addr encoderCtx)

  var swrCtx: ptr SwrContext = swr_alloc()
  if swrCtx == nil:
    error "Could not allocate resampler context"
  defer: swr_free(addr swrCtx)

  # Set resampler options
  if av_opt_set_chlayout(swrCtx, "in_chlayout", addr decoderCtx.ch_layout, 0) < 0:
    error "Could not set input channel layout"

  if av_opt_set_int(swrCtx, "in_sample_rate", decoderCtx.sample_rate, 0) < 0:
    error "Could not set input sample rate"

  if av_opt_set_sample_fmt(swrCtx, "in_sample_fmt", decoderCtx.sample_fmt, 0) < 0:
    error "Could not set input sample format"

  if av_opt_set_chlayout(swrCtx, "out_chlayout", addr encoderCtx.ch_layout, 0) < 0:
    error "Could not set output channel layout"

  if av_opt_set_int(swrCtx, "out_sample_rate", encoderCtx.sample_rate, 0) < 0:
    error "Could not set output sample rate"

  if av_opt_set_sample_fmt(swrCtx, "out_sample_fmt", encoderCtx.sample_fmt, 0) < 0:
    error "Could not set output sample format"

  if swr_init(swrCtx) < 0:
    error "Could not initialize resampler"

  # Add stream to output format
  let outputStream: ptr AVStream = avformat_new_stream(outputCtx, nil)
  if outputStream == nil:
    error "Could not allocate output stream"

  if avcodec_parameters_from_context(outputStream.codecpar, encoderCtx) < 0:
    error "Could not copy encoder parameters"

  outputStream.time_base = AVRational(num: 1, den: encoderCtx.sample_rate)
  outputStream.codecpar.codec_tag = 0 # Let the muxer choose the appropriate tag

  # Open output file
  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    ret = avio_open(addr outputCtx.pb, outputPath.cstring, AVIO_FLAG_WRITE)
    if ret < 0:
      error fmt"Could not open output file '{outputPath}'"

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"

  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  var convertedFrame = av_frame_alloc()

  if packet == nil or frame == nil or convertedFrame == nil:
    error "Could not allocate packet or frames"

  defer: av_packet_free(addr packet)
  defer: av_frame_free(addr frame)
  defer: av_frame_free(addr convertedFrame)

  # Track pts for output
  var currentPts: int64 = 0

  # Read and process frames
  while av_read_frame(container.formatContext, packet) >= 0:
    defer: av_packet_unref(packet)

    if packet.stream_index == audioStreamIdx:
      ret = avcodec_send_packet(decoderCtx, packet)
      if ret < 0 and ret != AVERROR_EAGAIN:
        echo fmt"Warning: Error sending packet to decoder (error code: {ret})"
        av_packet_unref(packet)
        continue

      while true:
        ret = avcodec_receive_frame(decoderCtx, frame)
        if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
          break
        elif ret < 0:
          error &"Error during decoding: {ret}"

        if processAndEncodeFrame(swrCtx, encoderCtx, outputCtx, outputStream,
                                frame, convertedFrame, currentPts,
                                frame.nb_samples,
                                cast[ptr ptr uint8](addr frame.data[0])):
          discard

        av_frame_unref(frame)

  # Flush decoder
  ret = avcodec_send_packet(decoderCtx, nil)
  if ret >= 0:
    while true:
      ret = avcodec_receive_frame(decoderCtx, frame)
      if ret == AVERROR_EOF or ret == AVERROR_EAGAIN:
        break
      elif ret < 0:
        break

      if processAndEncodeFrame(swrCtx, encoderCtx, outputCtx, outputStream,
                              frame, convertedFrame, currentPts,
                              frame.nb_samples,
                              cast[ptr ptr uint8](addr frame.data[0])):
        discard

      av_frame_unref(frame)

  while true:
    let delayedSamples = swr_get_delay(swrCtx, encoderCtx.sample_rate.int64)
    if delayedSamples <= 0:
      break

    if not processAndEncodeFrame(swrCtx, encoderCtx, outputCtx, outputStream,
                                frame, convertedFrame, currentPts,
                                cint(delayedSamples), nil):
      break

  # Flush encoder
  ret = avcodec_send_frame(encoderCtx, nil)
  if ret >= 0:
    while true:
      var outPacket = av_packet_alloc()
      ret = avcodec_receive_packet(encoderCtx, outPacket)
      if ret == AVERROR_EOF or ret == AVERROR_EAGAIN:
        av_packet_free(addr outPacket)
        break
      elif ret < 0:
        av_packet_free(addr outPacket)
        break

      outPacket.stream_index = outputStream.index
      av_packet_rescale_ts(outPacket, encoderCtx.time_base,
          outputStream.time_base)

      discard av_interleaved_write_frame(outputCtx, outPacket)
      av_packet_free(addr outPacket)

  discard av_write_trailer(outputCtx)
