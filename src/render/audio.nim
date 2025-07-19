import std/[strformat, os]
import std/tables

import ../log
import ../timeline
import ../[av, ffmpeg]
import ../resampler

type
  AudioFrame* = ref object
    data*: ptr UncheckedArray[ptr uint8]
    nb_samples*: int
    format*: AVSampleFormat
    sample_rate*: int
    ch_layout*: AVChannelLayout
    pts*: int64

  Getter* = ref object
    container*: InputContainer
    stream*: ptr AVStream
    decoderCtx*: ptr AVCodecContext
    rate*: int

proc newGetter*(path: string, stream: int, rate: int): Getter =
  result = new(Getter)
  result.container = av.open(path)
  result.stream = result.container.audio[stream]
  result.rate = rate
  result.decoderCtx = initDecoder(result.stream.codecpar)

proc close*(getter: Getter) =
  avcodec_free_context(addr getter.decoderCtx)
  getter.container.close()

proc get*(getter: Getter, start: int, endSample: int): seq[seq[int16]] =
  # start/end is in samples
  let container = getter.container
  let stream = getter.stream
  let decoderCtx = getter.decoderCtx

  let targetSamples = endSample - start

  # Initialize result with proper size and zero-filled data
  result = @[newSeq[int16](targetSamples), newSeq[int16](targetSamples)]

  # Fill with silence initially
  for ch in 0..<result.len:
    for i in 0..<targetSamples:
      result[ch][i] = 0

  # Convert sample position to time and seek
  let sampleRate = stream.codecpar.sample_rate
  let timeBase = stream.time_base
  let startTimeInSeconds = start.float / sampleRate.float
  let startPts = int64(startTimeInSeconds / (timeBase.num.float /
      timeBase.den.float))

  # Seek to the approximate position
  if av_seek_frame(container.formatContext, stream.index, startPts,
      AVSEEK_FLAG_BACKWARD) < 0:
    # If seeking fails, fall back to reading from beginning
    discard av_seek_frame(container.formatContext, stream.index, 0, AVSEEK_FLAG_BACKWARD)

  # Flush decoder after seeking
  avcodec_flush_buffers(decoderCtx)

  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  defer:
    av_packet_free(addr packet)
    av_frame_free(addr frame)

  var totalSamples = 0
  var samplesProcessed = 0

  # Decode frames until we have enough samples
  while av_read_frame(container.formatContext, packet) >= 0 and totalSamples < targetSamples:
    defer: av_packet_unref(packet)

    if packet.stream_index == stream.index:
      if avcodec_send_packet(decoderCtx, packet) >= 0:
        while avcodec_receive_frame(decoderCtx, frame) >= 0 and totalSamples < targetSamples:
          let channels = min(frame.ch_layout.nb_channels.int, 2) # Limit to stereo
          let samples = frame.nb_samples.int

          # Convert frame PTS to sample position
          let frameSamplePos = if frame.pts != AV_NOPTS_VALUE:
            int64(frame.pts.float * timeBase.num.float / timeBase.den.float *
                sampleRate.float)
          else:
            samplesProcessed.int64

          # If this frame is before our target start, skip it
          if frameSamplePos + samples.int64 <= start.int64:
            samplesProcessed += samples
            continue

          # Calculate how many samples to skip in this frame
          let samplesSkippedInFrame = max(0, start - frameSamplePos.int)
          let samplesInFrame = samples - samplesSkippedInFrame
          let samplesToProcess = min(samplesInFrame, targetSamples - totalSamples)

          # Process audio samples based on format
          if frame.format == AV_SAMPLE_FMT_S16.cint:
            # Interleaved 16-bit
            let audioData = cast[ptr UncheckedArray[int16]](frame.data[0])
            for i in 0..<samplesToProcess:
              let frameIndex = samplesSkippedInFrame + i
              for ch in 0..<channels:
                if totalSamples + i < targetSamples:
                  result[ch][totalSamples + i] = audioData[frameIndex *
                      channels + ch]

          elif frame.format == AV_SAMPLE_FMT_S16P.cint:
            # Planar 16-bit
            for i in 0..<samplesToProcess:
              let frameIndex = samplesSkippedInFrame + i
              for ch in 0..<channels:
                if totalSamples + i < targetSamples and frame.data[ch] != nil:
                  let channelData = cast[ptr UncheckedArray[int16]](frame.data[ch])
                  result[ch][totalSamples + i] = channelData[frameIndex]

          elif frame.format == AV_SAMPLE_FMT_FLT.cint:
            # Interleaved float
            let audioData = cast[ptr UncheckedArray[cfloat]](frame.data[0])
            for i in 0..<samplesToProcess:
              let frameIndex = samplesSkippedInFrame + i
              for ch in 0..<channels:
                if totalSamples + i < targetSamples:
                  # Convert float to 16-bit int with proper clamping
                  let floatSample = audioData[frameIndex * channels + ch]
                  let clampedSample = max(-1.0, min(1.0, floatSample))
                  result[ch][totalSamples + i] = int16(clampedSample * 32767.0)

          elif frame.format == AV_SAMPLE_FMT_FLTP.cint:
            # Planar float
            for i in 0..<samplesToProcess:
              let frameIndex = samplesSkippedInFrame + i
              for ch in 0..<channels:
                if totalSamples + i < targetSamples and frame.data[ch] != nil:
                  let channelData = cast[ptr UncheckedArray[cfloat]](frame.data[ch])
                  # Convert float to 16-bit int with proper clamping
                  let floatSample = channelData[frameIndex]
                  let clampedSample = max(-1.0, min(1.0, floatSample))
                  result[ch][totalSamples + i] = int16(clampedSample * 32767.0)
          else:
            # Unsupported format - samples already initialized to silence
            discard

          totalSamples += samplesToProcess
          samplesProcessed += samples

  # If we have mono input, duplicate to second channel
  if result.len >= 2 and result[0].len > 0 and result[1].len > 0:
    # Check if second channel is all zeros (mono source)
    var isSecondChannelEmpty = true
    for i in 0..<min(100, result[1].len): # Check first 100 samples
      if result[1][i] != 0:
        isSecondChannelEmpty = false
        break

    if isSecondChannelEmpty:
      # Copy first channel to second for stereo output
      for i in 0..<result[0].len:
        result[1][i] = result[0][i]

proc createAudioFilterGraph(clip: Clip, sr: int, channels: int): (ptr AVFilterGraph, ptr AVFilterContext, ptr AVFilterContext) =
  var filterGraph: ptr AVFilterGraph = avfilter_graph_alloc()
  var bufferSrc: ptr AVFilterContext = nil
  var bufferSink: ptr AVFilterContext = nil

  if filterGraph == nil:
    error "Could not allocate audio filter graph"

  # Create buffer source
  let channelLayoutStr = if channels == 1: "mono" else: "stereo"
  let bufferArgs = fmt"sample_rate={sr}:sample_fmt=s16p:channel_layout={channelLayoutStr}:time_base=1/{sr}"

  var ret = avfilter_graph_create_filter(addr bufferSrc, avfilter_get_by_name("abuffer"),
                                        "in", bufferArgs.cstring, nil, filterGraph)
  if ret < 0:
    error fmt"Cannot create audio buffer source: {ret}"

  # Create buffer sink
  ret = avfilter_graph_create_filter(addr bufferSink, avfilter_get_by_name("abuffersink"),
                                    "out", nil, nil, filterGraph)
  if ret < 0:
    error fmt"Cannot create audio buffer sink: {ret}"

  var filterChain = ""
  var needsFilters = false

  if clip.speed != 1.0:
    needsFilters = true
    let clampedSpeed = max(0.5, min(100.0, clip.speed))
    if filterChain != "":
      filterChain &= ","
    filterChain &= fmt"atempo={clampedSpeed}"

  if clip.volume != 1.0:
    needsFilters = true
    if filterChain != "":
      filterChain &= ","
    filterChain &= fmt"volume={clip.volume}"

  if not needsFilters:
    filterChain = "anull"

  var inputs = avfilter_inout_alloc()
  var outputs = avfilter_inout_alloc()
  if inputs == nil or outputs == nil:
    error "Could not allocate filter inputs/outputs"

  outputs.name = av_strdup("in")
  outputs.filter_ctx = bufferSrc
  outputs.pad_idx = 0
  outputs.next = nil

  inputs.name = av_strdup("out")
  inputs.filter_ctx = bufferSink
  inputs.pad_idx = 0
  inputs.next = nil

  ret = avfilter_graph_parse_ptr(filterGraph, filterChain.cstring, addr inputs, addr outputs, nil)
  if ret < 0:
    error fmt"Could not parse audio filter graph: {ret}"

  ret = avfilter_graph_config(filterGraph, nil)
  if ret < 0:
    error fmt"Could not configure audio filter graph: {ret}"

  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)

  return (filterGraph, bufferSrc, bufferSink)

proc processAudioClip*(clip: Clip, data: seq[seq[int16]], sr: int): seq[seq[int16]] =
  # If both speed and volume are unchanged, return original data
  if clip.speed == 1.0 and clip.volume == 1.0:
    return data

  if data.len == 0 or data[0].len == 0:
    return data

  let actualChannels = data.len
  let channels = if actualChannels == 1: 1 else: 2 # Determine if we have mono or stereo
  let samples = data[0].len

  # Create filter graph
  let (filterGraph, bufferSrc, bufferSink) = createAudioFilterGraph(clip, sr, channels)
  defer:
    if filterGraph != nil:
      avfilter_graph_free(addr filterGraph)

  # Create audio frame with input data
  var inputFrame = av_frame_alloc()
  if inputFrame == nil:
    error "Could not allocate input audio frame"
  defer: av_frame_free(addr inputFrame)

  inputFrame.nb_samples = samples.cint
  inputFrame.format = AV_SAMPLE_FMT_S16P.cint
  inputFrame.ch_layout.nb_channels = channels.cint
  inputFrame.ch_layout.order = 0
  if channels == 1:
    inputFrame.ch_layout.u.mask = 1 # AV_CH_LAYOUT_MONO
  else:
    inputFrame.ch_layout.u.mask = 3 # AV_CH_LAYOUT_STEREO
  inputFrame.sample_rate = sr.cint
  inputFrame.pts = AV_NOPTS_VALUE  # Let the filter handle timing

  if av_frame_get_buffer(inputFrame, 0) < 0:
    error "Could not allocate input audio frame buffer"

  # Copy input data to frame (planar format)
  for ch in 0..<channels:
    let channelData = cast[ptr UncheckedArray[int16]](inputFrame.data[ch])
    for i in 0..<samples:
      if ch == 0:
        # Always copy first channel
        if i < data[0].len:
          channelData[i] = data[0][i]
        else:
          channelData[i] = 0
      elif ch == 1:
        # For second channel: use second channel if available, otherwise duplicate first
        if actualChannels >= 2 and i < data[1].len:
          channelData[i] = data[1][i]
        elif i < data[0].len:
          channelData[i] = data[0][i]  # Duplicate mono to stereo
        else:
          channelData[i] = 0
      else:
        # Should not happen with our logic, but just in case
        channelData[i] = 0

  # Process through filter graph
  var outputFrames: seq[ptr AVFrame] = @[]
  defer:
    for frame in outputFrames:
      av_frame_free(addr frame)

  # Send frame to filter
  if av_buffersrc_write_frame(bufferSrc, inputFrame) < 0:
    error "Error adding frame to audio filter"

  # Flush filter by sending null frame
  if av_buffersrc_write_frame(bufferSrc, nil) < 0:
    error "Error flushing audio filter"

  # Collect output frames
  while true:
    var outputFrame = av_frame_alloc()
    if outputFrame == nil:
      error "Could not allocate output audio frame"

    let ret = av_buffersink_get_frame(bufferSink, outputFrame)
    if ret < 0:
      av_frame_free(addr outputFrame)
      break

    outputFrames.add(outputFrame)

  # Convert output frames back to seq[seq[int16]]
  if outputFrames.len == 0:
    # No output frames, return empty data
    result = @[newSeq[int16](0), newSeq[int16](0)]
    return

  # Calculate total output samples
  var totalSamples = 0
  for frame in outputFrames:
    totalSamples += frame.nb_samples.int


  # Initialize result with proper size
  result = @[newSeq[int16](totalSamples), newSeq[int16](totalSamples)]

  # Copy data from output frames
  var sampleOffset = 0
  for frame in outputFrames:
    let frameSamples = frame.nb_samples.int
    let frameChannels = min(frame.ch_layout.nb_channels.int, 2)

    # Handle different output formats from the filter
    if frame.format == AV_SAMPLE_FMT_S16P.cint:
      # Planar format - each channel has its own data array
      for ch in 0..<min(result.len, frameChannels):
        if frame.data[ch] != nil:
          let channelData = cast[ptr UncheckedArray[int16]](frame.data[ch])
          for i in 0..<frameSamples:
            if sampleOffset + i < result[ch].len:
              result[ch][sampleOffset + i] = channelData[i]
    elif frame.format == AV_SAMPLE_FMT_S16.cint:
      # Interleaved format - all channels in one data array
      let audioData = cast[ptr UncheckedArray[int16]](frame.data[0])
      for i in 0..<frameSamples:
        for ch in 0..<min(result.len, frameChannels):
          if sampleOffset + i < result[ch].len:
            result[ch][sampleOffset + i] = audioData[i * frameChannels + ch]
    else:
      # Unsupported format - skip this frame or convert
      error fmt"Unsupported output frame format: {frame.format}"

    sampleOffset += frameSamples

  # If we have mono input, duplicate to second channel
  if result.len >= 2 and result[0].len > 0 and result[1].len > 0:
    var isSecondChannelEmpty = true
    for i in 0..<min(100, result[1].len):
      if result[1][i] != 0:
        isSecondChannelEmpty = false
        break

    if isSecondChannelEmpty:
      for i in 0..<result[0].len:
        result[1][i] = result[0][i]

proc ndArrayToFile*(audioData: seq[seq[int16]], rate: int, outputPath: string) =
  var output = openWrite(outputPath)
  let outputCtx = output.formatCtx
  defer: output.close()

  let (encoder, encoderCtx) = initEncoder("pcm_s16le")
  defer: avcodec_free_context(addr encoderCtx)

  encoderCtx.sample_rate = rate.cint
  encoderCtx.ch_layout.nb_channels = audioData.len.cint
  encoderCtx.ch_layout.order = 0
  if audioData.len == 1:
    encoderCtx.ch_layout.u.mask = 1 # AV_CH_LAYOUT_MONO
  else:
    encoderCtx.ch_layout.u.mask = 3 # AV_CH_LAYOUT_STEREO
  encoderCtx.sample_fmt = AV_SAMPLE_FMT_S16 # Use interleaved format
  encoderCtx.time_base = AVRational(num: 1, den: rate.cint)

  if avcodec_open2(encoderCtx, encoder, nil) < 0:
    error "Could not open encoder"

  # Copy codec parameters to stream
  let stream = avformat_new_stream(outputCtx, nil)
  if stream == nil:
    error "Could not create audio stream"
  discard avcodec_parameters_from_context(stream.codecpar, encoderCtx)

  output.startEncoding()

  # Write all audio data in chunks
  if audioData.len > 0 and audioData[0].len > 0:
    let totalSamples = audioData[0].len
    let samplesPerFrame = 1024 # Process in chunks of 1024 samples
    var samplesWritten = 0

    while samplesWritten < totalSamples:
      let currentFrameSize = min(samplesPerFrame, totalSamples - samplesWritten)

      var frame = av_frame_alloc()
      if frame == nil:
        error "Could not allocate audio frame"
      defer: av_frame_free(addr frame)

      frame.nb_samples = currentFrameSize.cint
      frame.format = AV_SAMPLE_FMT_S16.cint
      frame.ch_layout = encoderCtx.ch_layout
      frame.sample_rate = rate.cint

      if av_frame_get_buffer(frame, 0) < 0:
        error "Could not allocate audio frame buffer"

      # Fill frame with actual audio data
      let channelData = cast[ptr UncheckedArray[int16]](frame.data[0])
      for i in 0..<currentFrameSize:
        let srcIndex = samplesWritten + i
        for ch in 0..<min(audioData.len, frame.ch_layout.nb_channels.int):
          let interleavedIndex = i * frame.ch_layout.nb_channels.int + ch
          if ch < audioData.len and srcIndex < audioData[ch].len:
            channelData[interleavedIndex] = audioData[ch][srcIndex]
          else:
            channelData[interleavedIndex] = 0

      # Set presentation timestamp
      frame.pts = samplesWritten.int64

      # Send frame to encoder
      if avcodec_send_frame(encoderCtx, frame) >= 0:
        var packet = av_packet_alloc()
        if packet == nil:
          error "Could not allocate packet"
        defer: av_packet_free(addr packet)

        while avcodec_receive_packet(encoderCtx, packet) >= 0:
          packet.stream_index = stream.index
          discard av_interleaved_write_frame(outputCtx, packet)
          av_packet_unref(packet)

      samplesWritten += currentFrameSize

  # Flush encoder
  if avcodec_send_frame(encoderCtx, nil) >= 0:
    var packet = av_packet_alloc()
    if packet == nil:
      error "Could not allocate packet"
    defer: av_packet_free(addr packet)

    while avcodec_receive_packet(encoderCtx, packet) >= 0:
      packet.stream_index = stream.index
      discard av_interleaved_write_frame(outputCtx, packet)
      av_packet_unref(packet)


iterator makeNewAudioFrames*(tl: v3, tempDir: string, targetSampleRate: int, targetChannels: int): (ptr AVFrame, int) =
  # Generator that yields audio frames directly for use in makeMedia
  var samples: Table[(string, int32), Getter]

  if tl.a.len == 0 or tl.a[0].len == 0:
    error "Trying to render empty audio timeline"

  # For now, process the first audio layer
  let layer = tl.a[0] 
  if layer.len > 0:  # Only process if layer has clips
    # Create getters for all unique sources
    for clip in layer:
      let key = (clip.src[], clip.stream)
      if key notin samples:
        samples[key] = newGetter(clip.src[], clip.stream.int, targetSampleRate)

    # Calculate total duration and create audio buffer
    var totalDuration = 0
    for clip in layer:
      totalDuration = max(totalDuration, clip.start + clip.dur)

    let totalSamples = int(totalDuration * targetSampleRate.int64 * tl.tb.den div tl.tb.num)
    var audioData = @[newSeq[int16](totalSamples), newSeq[int16](totalSamples)]

    # Initialize with silence
    for ch in 0..<audioData.len:
      for i in 0..<totalSamples:
        audioData[ch][i] = 0

    # Process each clip and mix into the output
    for clip in layer:
      let key = (clip.src[], clip.stream)
      if key in samples:
        let sampStart = int(clip.offset.float64 * clip.speed * targetSampleRate.float64 / tl.tb)
        let sampEnd = int(float64(clip.offset + clip.dur) * clip.speed * targetSampleRate.float64 / tl.tb)

        let getter = samples[key]
        let srcData = getter.get(sampStart, sampEnd)

        let startSample = int(clip.start * targetSampleRate.int64 * tl.tb.den div tl.tb.num)
        let durSamples = int(clip.dur * targetSampleRate.int64 * tl.tb.den div tl.tb.num)
        let processedData = processAudioClip(clip, srcData, targetSampleRate)
        
        if processedData.len > 0:
          for ch in 0 ..< min(audioData.len, processedData.len):
            for i in 0 ..< min(durSamples, processedData[ch].len):
              let outputIndex = startSample + i
              if outputIndex < audioData[ch].len:
                let currentSample = audioData[ch][outputIndex].int32
                let newSample = processedData[ch][i].int32
                let mixed = currentSample + newSample
                # Clamp to 16-bit range to prevent overflow distortion
                audioData[ch][outputIndex] = int16(max(-32768, min(32767, mixed)))

    # Yield audio frames in chunks
    const frameSize = 1024
    var samplesYielded = 0
    var frameIndex = 0

    var resampler = newAudioResampler(AV_SAMPLE_FMT_FLTP, "stereo", tl.sr)
    
    while samplesYielded < totalSamples:
      let currentFrameSize = min(frameSize, totalSamples - samplesYielded)
      
      var frame = av_frame_alloc()
      if frame == nil:
        error "Could not allocate audio frame"
      
      frame.nb_samples = currentFrameSize.cint
      frame.format = AV_SAMPLE_FMT_S16P.cint  # Planar format
      frame.ch_layout.nb_channels = targetChannels.cint
      frame.ch_layout.order = 0
      if targetChannels == 1:
        frame.ch_layout.u.mask = 1  # AV_CH_LAYOUT_MONO
      else:
        frame.ch_layout.u.mask = 3  # AV_CH_LAYOUT_STEREO
      frame.sample_rate = targetSampleRate.cint
      frame.pts = samplesYielded.int64
      
      if av_frame_get_buffer(frame, 0) < 0:
        av_frame_free(addr frame)
        error "Could not allocate audio frame buffer"
      
      # Copy audio data to frame (planar format)
      for ch in 0..<min(targetChannels, audioData.len):
        let channelData = cast[ptr UncheckedArray[int16]](frame.data[ch])
        for i in 0..<currentFrameSize:
          let srcIndex = samplesYielded + i
          if ch < audioData.len and srcIndex < audioData[ch].len:
            channelData[i] = audioData[ch][srcIndex]
          else:
            channelData[i] = 0
      
      for newFrame in resampler.resample(frame):
        yield (newFrame, frameIndex)
        frameIndex += 1
      samplesYielded += currentFrameSize

    # Close all getters
    for getter in samples.values:
      getter.close()

proc makeNewAudio*(tl: v3, outputDir: string): seq[string] =
  var samples: Table[(string, int32), Getter]

  if tl.a.len == 0 or tl.a[0].len == 0:
    error "Trying to render empty audio timeline"

  for i, layer in tl.a:
    if layer.len == 0:
      continue

    conwrite("Creating audio")

    for clip in layer:
      let key = (clip.src[], clip.stream)
      if key notin samples:
        samples[key] = newGetter(clip.src[], clip.stream.int, tl.sr.int)

    let outputPath = outputDir / &"new{i}.wav"
    var totalDuration = 0
    for clip in layer:
      totalDuration = max(totalDuration, clip.start + clip.dur)

    # Create stereo audio data
    let totalSamples = int(totalDuration * tl.sr.int64 * tl.tb.den div tl.tb.num)
    var audioData = @[newSeq[int16](totalSamples), newSeq[int16](totalSamples)]

    # Initialize with silence
    for ch in 0..<audioData.len:
      for i in 0..<totalSamples:
        audioData[ch][i] = 0

    # Process each clip and mix into the output
    for clip in layer:
      let key = (clip.src[], clip.stream)
      if key in samples:
        let sampStart = int(clip.offset.float64 * clip.speed * tl.sr.float64 / tl.tb)
        let sampEnd = int(float64(clip.offset + clip.dur) * clip.speed * tl.sr.float64 / tl.tb)

        let getter = samples[key]
        let srcData = getter.get(sampStart, sampEnd)

        let startSample = int(clip.start * tl.sr.int64 * tl.tb.den div tl.tb.num)
        let durSamples = int(clip.dur * tl.sr.int64 * tl.tb.den div tl.tb.num)
        let processedData = processAudioClip(clip, srcData, tl.sr.int)
        if processedData.len > 0:
          for ch in 0 ..< min(audioData.len, processedData.len):
            for i in 0 ..< min(durSamples, processedData[ch].len):
              let outputIndex = startSample + i
              if outputIndex < audioData[ch].len:
                let currentSample = audioData[ch][outputIndex].int32
                let newSample = processedData[ch][i].int32
                let mixed = currentSample + newSample
                # Clamp to 16-bit range to prevent overflow distortion
                audioData[ch][outputIndex] = int16(max(-32768, min(32767, mixed)))

    # Write the processed audio to file
    result.add(outputPath)
    ndArrayToFile(audioData, tl.sr.int, outputPath)

  # Close all getters
  for getter in samples.values:
    getter.close()
