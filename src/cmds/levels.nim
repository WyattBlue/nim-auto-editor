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
    exactSize: float64
    accumulatedError: float64
    sampleRate: int
    channelCount: cint
    targetFormat: AVSampleFormat
    isInitialized: bool
    totalFramesProcessed: int
    totalSamplesWritten: int

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

  # echo "AudioIterator initialized:"
  # echo "  Sample rate: ", sampleRate
  # echo "  Channels: ", channelLayout.nb_channels
  # echo "  Time base: ", timeBase
  # echo "  Exact chunk size: ", result.exactSize, " samples"
  # echo "  Chunk duration: ", result.exactSize / float64(sampleRate), " seconds"

  # Initialize audio FIFO
  result.fifo = av_audio_fifo_alloc(result.targetFormat, result.channelCount, 1024)
  if result.fifo == nil:
    error "Could not allocate audio FIFO"

proc cleanup*(iter: AudioIterator) =
  if iter.fifo != nil:
    av_audio_fifo_free(iter.fifo)
    iter.fifo = nil
  if iter.swrCtx != nil:
    swr_free(addr iter.swrCtx)
    iter.swrCtx = nil

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

  # Allocate output frame for resampling
  let outputFrame = av_frame_alloc()
  if outputFrame == nil:
    error "Could not allocate output frame"
  defer: av_frame_free(addr outputFrame)

  # Set output frame properties
  outputFrame.format = iter.targetFormat.cint
  outputFrame.ch_layout = frame.ch_layout
  outputFrame.sample_rate = iter.sampleRate.cint
  outputFrame.nb_samples = frame.nb_samples

  # Allocate buffer for output frame
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
  defer: av_freep(addr buffer)

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

# Global iterator instance
var globalAudioIterator: AudioIterator = nil

proc process_audio_frame(chunkDuration: float64, frame: ptr AVFrame) =
  if globalAudioIterator == nil:
    globalAudioIterator = newAudioIterator(frame.sample_rate, frame.ch_layout, chunkDuration)

  # Write frame to iterator
  globalAudioIterator.writeFrame(frame)

  # Process any available chunks
  var chunksProcessed = 0
  while globalAudioIterator.hasChunk():
    let loudness = globalAudioIterator.readChunk()
    chunksProcessed += 1
    echo loudness


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

  defer:
    if globalAudioIterator != nil:
      globalAudioIterator.cleanup()

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

  let formatCtx = container.formatContext
  if container.audio.len == 0:
    error "No audio stream"
  if userStream < 0:
    error "Stream must be positive"
  if container.audio.len <= userStream:
    error fmt"Audio stream out of range: {userStream}"

  let audioStream: ptr AVStream = container.audio[userStream]
  let audioIndex: cint = audioStream.index
  let codecCtx = initDecoder(audioStream.codecpar)
  defer: avcodec_free_context(addr codecCtx)

  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  if packet == nil or frame == nil:
    error "Could not allocate packet/frame"

  defer:
    av_packet_free(addr packet)
    av_frame_free(addr frame)

  echo "\n@start"

  var ret: cint
  while av_read_frame(formatCtx, packet) >= 0:
    defer: av_packet_unref(packet)

    if packet.stream_index == audioIndex:
      ret = avcodec_send_packet(codecCtx, packet)
      if ret < 0:
        error "sending packet to decoder"

      while ret >= 0:
        ret = avcodec_receive_frame(codecCtx, frame)
        if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
          break
        elif ret < 0:
          error "Error receiving frame from decoder"

        process_audio_frame(chunkDuration, frame)

  # Flush decoder
  discard avcodec_send_packet(codecCtx, nil)
  while avcodec_receive_frame(codecCtx, frame) >= 0:
    process_audio_frame(chunkDuration, frame)

  if globalAudioIterator != nil:
    while globalAudioIterator.hasChunk():
      let loudness = globalAudioIterator.readChunk()
      echo "Final loudness ", loudness
      error "Final"

  echo ""
