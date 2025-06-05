import std/math
import std/parseopt
import std/strformat
import std/strutils

import ../av
import ../ffmpeg
import ../log

type
  AudioIterator* = ref object
    fifo: ptr AVAudioFifo
    swrCtx: ptr SwrContext
    outputFrame: ptr AVFrame
    exactSize: float64
    accumulatedError: float64
    sampleRate: int
    channelCount: cint
    targetFormat: AVSampleFormat
    isInitialized: bool
    totalFramesProcessed: int
    totalSamplesWritten: int

  AudioProcessor* = object
    formatCtx: ptr AVFormatContext
    `iterator`: AudioIterator
    codecCtx: ptr AVCodecContext
    audioIndex: cint
    chunkDuration: float64

proc newAudioIterator*(sampleRate: int, channelLayout: AVChannelLayout, timeBase: float64): AudioIterator =
  result = AudioIterator()
  result.sampleRate = sampleRate
  result.channelCount = channelLayout.nb_channels
  result.targetFormat = AV_SAMPLE_FMT_FLT  # 32-bit float, interleaved
  result.exactSize = timeBase * float64(sampleRate)  # chunk duration in seconds * samples per second
  result.accumulatedError = 0.0
  result.isInitialized = false
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

proc cleanup*(iter: AudioIterator) =
  if iter.fifo != nil:
    av_audio_fifo_free(iter.fifo)
    iter.fifo = nil
  if iter.swrCtx != nil:
    swr_free(addr iter.swrCtx)
    iter.swrCtx = nil
  if iter.outputFrame != nil:
    av_frame_free(addr iter.outputFrame)
    iter.outputFrame = nil

proc initResampler*(iter: AudioIterator, inputFormat: AVSampleFormat, inputLayout: AVChannelLayout) =
  if iter.isInitialized:
    return

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

proc writeFrame*(iter: AudioIterator, frame: ptr AVFrame) =
  # Initialize resampler on first frame
  if not iter.isInitialized:
    iter.initResampler(AVSampleFormat(frame.format), frame.ch_layout)

  iter.totalFramesProcessed += 1

  # Reuse the existing output frame
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

proc hasChunk*(iter: AudioIterator): bool =
  let availableSamples = av_audio_fifo_size(iter.fifo)
  let needed = ceil(iter.exactSize).int
  return availableSamples >= needed

proc readChunk*(iter: AudioIterator): float32 =
  # Calculate chunk size with accumulated error
  let sizeWithError = iter.exactSize + iter.accumulatedError
  let currentSize = round(sizeWithError).int
  iter.accumulatedError = sizeWithError - float64(currentSize)

  var buffer: ptr uint8
  let ret = av_samples_alloc(addr buffer, nil, iter.channelCount.cint,
                           currentSize.cint, iter.targetFormat, 0)
  if ret < 0:
    error "Could not allocate sample buffer"
  defer:
    av_freep(addr buffer)

  # Read from FIFO
  let samplesRead = av_audio_fifo_read(iter.fifo, cast[pointer](addr buffer), currentSize.cint)
  if samplesRead != currentSize:
    echo "Warning: requested ", currentSize, " samples, got ", samplesRead

  # Calculate maximum absolute value
  let samples = cast[ptr UncheckedArray[float32]](buffer)
  let totalSamples = samplesRead * iter.channelCount
  var maxAbs: float32 = 0.0

  for i in 0 ..< totalSamples:
    let absVal = abs(samples[i])
    if absVal > maxAbs:
      maxAbs = absVal

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
          error "Error receiving frame from decoder"

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


type levelArgs* = object
  input*: string
  timebase*: string = "30/1"
  edit*: string = "audio"

# TODO: Make a generic version
proc parseEditString*(exportStr: string): (string, string) =
  var kind = exportStr
  var stream = "0"

  let colonPos = exportStr.find(':')
  if colonPos == -1:
    return (kind, stream)

  kind = exportStr[0..colonPos-1]
  let paramsStr = exportStr[colonPos+1..^1]

  var i = 0
  while i < paramsStr.len:
    while i < paramsStr.len and paramsStr[i] == ' ':
      inc i

    if i >= paramsStr.len:
      break

    var paramStart = i
    while i < paramsStr.len and paramsStr[i] != '=':
      inc i

    if i >= paramsStr.len:
      break

    let paramName = paramsStr[paramStart..i-1]
    inc i

    var value = ""
    if i < paramsStr.len and paramsStr[i] == '"':
      inc i
      while i < paramsStr.len:
        if paramsStr[i] == '\\' and i + 1 < paramsStr.len:
          # Handle escape sequences
          inc i
          case paramsStr[i]:
            of '"': value.add('"')
            of '\\': value.add('\\')
            else:
              value.add('\\')
              value.add(paramsStr[i])
        elif paramsStr[i] == '"':
          inc i
          break
        else:
          value.add(paramsStr[i])
        inc i
    else:
      # Unquoted value (until comma or end)
      while i < paramsStr.len and paramsStr[i] != ',':
        value.add(paramsStr[i])
        inc i

    case paramName:
      of "stream": stream = value

    # Skip comma
    if i < paramsStr.len and paramsStr[i] == ',':
      inc i

  return (kind, stream)

proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Display loudness over time"
    quit(0)

  var args = levelArgs()
  var expecting: string = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      case expecting
      of "":
        args.input = key
      of "timebase":
        args.timebase = key
      of "edit":
        args.edit = key
      expecting = ""

    of cmdLongOption:
      if key in ["edit", "timebase"]:
        expecting = key
      else:
        error(fmt"Unknown option: {key}")
    of cmdShortOption:
      if key == "t":
        discard
      elif key == "b":
        expecting = "timebase"
      else:
        error(fmt"Unknown option: {key}")
    of cmdEnd:
      discard

  if expecting != "":
    error(fmt"--{expecting} needs argument.")

  av_log_set_level(AV_LOG_QUIET)
  let inputFile = args.input
  let chunkDuration: float64 = av_inv_q(AVRational(args.timebase))
  let (editMethod, streamStr) = parseEditString(args.edit)
  if editMethod != "audio":
    error fmt"Unknown editing method: {editMethod}"
  let userStream = parseInt(streamStr)

  var container: InputContainer
  try:
    container = av.open(inputFile)
  except IOError as e:
    error e.msg
  defer: container.close()

  if container.audio.len == 0:
    error "No audio stream"
  if userStream < 0:
    error "Stream must be positive"
  if container.audio.len <= userStream:
    error fmt"Audio stream out of range: {userStream}"

  let audioStream: ptr AVStream = container.audio[userStream]
  let audioIndex: cint = audioStream.index

  var processor = AudioProcessor(
    formatCtx: container.formatContext,
    codecCtx: initDecoder(audioStream.codecpar),
    audioIndex: audioIndex,
    chunkDuration: chunkDuration
  )

  echo "\n@start"

  for loudnessValue in processor.loudness():
    echo loudnessValue

  echo ""