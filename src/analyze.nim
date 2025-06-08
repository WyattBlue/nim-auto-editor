import std/math
import std/strformat

import ffmpeg
import av
import log
import util/bar

# Enable project wide, see: https://simonbyrne.github.io/notes/fastmath/
{.passC: "-ffast-math".}
{.passL: "-flto".}

type
  AudioIterator = ref object
    fifo: ptr AVAudioFifo
    swrCtx: ptr SwrContext
    outputFrame: ptr AVFrame
    exactSize: float64
    accumulatedError: float64
    sampleRate: cint
    channelCount: cint
    targetFormat: AVSampleFormat
    isInitialized: bool
    needsResampling: bool
    totalFramesProcessed: int
    totalSamplesWritten: int
    readBuffer: ptr uint8
    maxBufferSize: int

  AudioProcessor* = object
    formatCtx*: ptr AVFormatContext
    `iterator`*: AudioIterator
    codecCtx*: ptr AVCodecContext
    audioIndex*: cint
    chunkDuration*: float64

proc newAudioIterator(sampleRate: cint, channelLayout: AVChannelLayout, chunkDuration: float64): AudioIterator =
  result = AudioIterator()
  result.sampleRate = sampleRate
  result.channelCount = channelLayout.nb_channels
  result.targetFormat = AV_SAMPLE_FMT_FLT  # 32-bit float, interleaved
  result.exactSize = chunkDuration * float64(sampleRate)
  result.accumulatedError = 0.0
  result.isInitialized = false
  result.needsResampling = false
  result.totalFramesProcessed = 0
  result.totalSamplesWritten = 0

  # Initialize audio FIFO
  result.fifo = av_audio_fifo_alloc(result.targetFormat, result.channelCount, 1024)
  if result.fifo == nil:
    error "Could not allocate audio FIFO"

  # Allocate output frame once
  result.outputFrame = av_frame_alloc()
  if result.outputFrame == nil:
    error "Could not allocate output frame"

  # Pre-allocate buffer for reading chunks
  result.maxBufferSize = int(result.exactSize)
  let ret = av_samples_alloc(addr result.readBuffer, nil, result.channelCount.cint,
                           result.maxBufferSize.cint, result.targetFormat, 0)
  if ret < 0:
    error "Could not allocate read buffer"

proc cleanup(iter: AudioIterator) =
  if iter.fifo != nil:
    av_audio_fifo_free(iter.fifo)
    iter.fifo = nil
  if iter.swrCtx != nil:
    swr_free(addr iter.swrCtx)
    iter.swrCtx = nil
  if iter.outputFrame != nil:
    av_frame_free(addr iter.outputFrame)
    iter.outputFrame = nil
  if iter.readBuffer != nil:
    av_freep(addr iter.readBuffer)
    iter.readBuffer = nil

proc initResampler(iter: AudioIterator, inputFormat: AVSampleFormat, inputLayout: AVChannelLayout) =
  if iter.isInitialized:
    return

  if inputFormat == AV_SAMPLE_FMT_FLT:
    iter.needsResampling = false
    iter.isInitialized = true
    return

  iter.needsResampling = true

  iter.swrCtx = swr_alloc()
  if iter.swrCtx == nil:
    error "Could not allocate resampler context"

  # Set input parameters
  if av_opt_set_chlayout(iter.swrCtx, "in_chlayout", unsafeAddr inputLayout, 0) < 0:
    error "Could not set input channel layout"
  if av_opt_set_int(iter.swrCtx, "in_sample_rate", iter.sampleRate, 0) < 0:
    error "Could not set input sample rate"
  if av_opt_set_sample_fmt(iter.swrCtx, "in_sample_fmt", inputFormat, 0) < 0:
    error "Could not set input sample format"

  # Set output parameters (target format)
  var outputLayout = inputLayout  # Keep same layout
  if av_opt_set_chlayout(iter.swrCtx, "out_chlayout", unsafeAddr outputLayout, 0) < 0:
    error "Could not set output channel layout"
  if av_opt_set_int(iter.swrCtx, "out_sample_rate", iter.sampleRate, 0) < 0:
    error "Could not set output sample rate"
  if av_opt_set_sample_fmt(iter.swrCtx, "out_sample_fmt", iter.targetFormat, 0) < 0:
    error "Could not set output sample format"

  if swr_init(iter.swrCtx) < 0:
    error "Could not initialize resampler"

  iter.isInitialized = true

proc writeFrame(iter: AudioIterator, frame: ptr AVFrame) =
  # Initialize resampler on first frame
  if not iter.isInitialized:
    iter.initResampler(AVSampleFormat(frame.format), frame.ch_layout)

  iter.totalFramesProcessed += 1

  # Passthrough for compatible formats
  if not iter.needsResampling:
    # Write frame directly to FIFO without conversion
    let ret = av_audio_fifo_write(iter.fifo, cast[pointer](addr frame.data[0]), frame.nb_samples)
    if ret < frame.nb_samples:
      error "Could not write data to FIFO"
    iter.totalSamplesWritten += frame.nb_samples
    return

  # Reuse the existing output frame for resampling
  let outputFrame = iter.outputFrame

  # Reset frame properties for reuse
  av_frame_unref(outputFrame)

  # Set output frame properties
  outputFrame.format = iter.targetFormat.cint
  outputFrame.ch_layout = frame.ch_layout
  outputFrame.sample_rate = iter.sampleRate.cint
  outputFrame.nb_samples = frame.nb_samples

  # Allocate buffer for output frame (this will reuse or reallocate as needed)
  if av_frame_get_buffer(outputFrame, 0) < 0:
    error "Could not allocate output frame buffer"

  # Convert the audio
  let convertedSamples = swr_convert(iter.swrCtx,
                                   cast[ptr ptr uint8](addr outputFrame.data[0]),
                                   frame.nb_samples,
                                   cast[ptr ptr uint8](addr frame.data[0]),
                                   frame.nb_samples)

  if convertedSamples < 0:
    error "Error converting audio samples"

  outputFrame.nb_samples = convertedSamples

  # Write converted frame to FIFO
  let ret = av_audio_fifo_write(iter.fifo, cast[pointer](addr outputFrame.data[0]), convertedSamples)
  if ret < convertedSamples:
    error "Could not write data to FIFO"

  iter.totalSamplesWritten += convertedSamples

proc hasChunk(iter: AudioIterator): bool =
  let availableSamples = av_audio_fifo_size(iter.fifo)
  let needed = ceil(iter.exactSize).int
  return availableSamples >= needed

proc readChunk(iter: AudioIterator): float32 =
  # Calculate chunk size with accumulated error
  let sizeWithError = iter.exactSize + iter.accumulatedError
  let currentSize = round(sizeWithError).int
  iter.accumulatedError = sizeWithError - float64(currentSize)

  # Use pre-allocated buffer - no allocation needed!
  let samples = cast[ptr UncheckedArray[float32]](iter.readBuffer)
  let samplesRead = av_audio_fifo_read(iter.fifo, cast[pointer](addr iter.readBuffer), currentSize.cint)
  let totalSamples = samplesRead * iter.channelCount

  # Process 4 floats at once using SIMD-like operations
  let simdWidth = 4
  let simdSamples = totalSamples and not (simdWidth - 1)  # Round down to multiple of 4

  var maxAbs: float32 = 0.0

  # SIMD-style loop (unrolled)
  for i in countup(0, simdSamples - 1, simdWidth):
    let v0 = abs(samples[i])
    let v1 = abs(samples[i + 1])
    let v2 = abs(samples[i + 2])
    let v3 = abs(samples[i + 3])

    maxAbs = max(maxAbs, max(max(v0, v1), max(v2, v3)))

  # Handle remaining samples
  for i in simdSamples ..< totalSamples:
    maxAbs = max(maxAbs, abs(samples[i]))

  return maxAbs

iterator loudness*(processor: var AudioProcessor): float32 =
  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  if packet == nil or frame == nil:
    error "Could not allocate packet/frame"

  defer:
    av_packet_free(addr packet)
    av_frame_free(addr frame)
    if processor.`iterator` != nil:
      processor.`iterator`.cleanup()
    avcodec_free_context(addr processor.codecCtx)

  var ret: cint
  while av_read_frame(processor.formatCtx, packet) >= 0:
    defer: av_packet_unref(packet)

    if packet.stream_index == processor.audioIndex:
      ret = avcodec_send_packet(processor.codecCtx, packet)
      if ret < 0:
        error "sending packet to decoder"

      while ret >= 0:
        ret = avcodec_receive_frame(processor.codecCtx, frame)
        if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
          break
        elif ret < 0:
          error fmt"Error receiving frame from decoder: {ret}"

        if processor.`iterator` == nil:
          processor.`iterator` = newAudioIterator(frame.sample_rate, frame.ch_layout, processor.chunkDuration)

        processor.`iterator`.writeFrame(frame)

        while processor.`iterator`.hasChunk():
          yield processor.`iterator`.readChunk()

  # Flush decoder
  discard avcodec_send_packet(processor.codecCtx, nil)
  while avcodec_receive_frame(processor.codecCtx, frame) >= 0:
    if processor.`iterator` != nil:
      processor.`iterator`.writeFrame(frame)
      while processor.`iterator`.hasChunk():
        yield processor.`iterator`.readChunk()


proc audio*(bar: Bar, tb: AVRational, container: InputContainer, stream: int64): seq[float32] =
  if stream >= container.audio.len:
    error fmt"audio: audio stream '{stream}' does not exist."

  let audioStream: ptr AVStream = container.audio[stream]

  var processor = AudioProcessor(
    formatCtx: container.formatContext,
    codecCtx: initDecoder(audioStream.codecpar),
    audioIndex: audioStream.index,
    chunkDuration: av_inv_q(tb),
  )

  var inaccurateDur: float = 1024.0
  if audioStream.duration != AV_NOPTS_VALUE and audioStream.time_base != AV_NOPTS_VALUE:
    inaccurateDur = float(audioStream.duration) * float(audioStream.time_base * tb)
  elif container.duration != 0.0:
    inaccurateDur = container.duration / float(tb)

  bar.start(inaccurateDur, "Analyzing audio volume")
  var i: float = 0
  for value in processor.loudness():
    result.add value
    bar.tick(i)
    i += 1

  bar.`end`()
