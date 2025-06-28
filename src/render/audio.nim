import std/[strformat, os]
import std/tables

import ../log
import ../timeline
import ../[av, ffmpeg]

type
  AudioFrame* = ref object
    data*: ptr UncheckedArray[ptr uint8]
    nb_samples*: int
    format*: AVSampleFormat
    sample_rate*: int
    ch_layout*: AVChannelLayout
    pts*: int64

  AudioResampler* = ref object
    swrCtx*: ptr SwrContext
    outputFormat*: AVSampleFormat
    outputLayout*: AVChannelLayout
    outputSampleRate*: int

  Getter* = ref object
    container*: InputContainer
    stream*: ptr AVStream
    decoderCtx*: ptr AVCodecContext
    rate*: int

proc newAudioResampler*(format: AVSampleFormat, layout: string,
  rate: int): AudioResampler =
  result = new(AudioResampler)
  result.swrCtx = swr_alloc()
  result.outputFormat = format
  result.outputSampleRate = rate

  # Set up output channel layout
  var outputLayout: AVChannelLayout
  if layout == "stereo":
    outputLayout.nb_channels = 2
    outputLayout.order = 0
    outputLayout.u.mask = 3 # AV_CH_LAYOUT_STEREO
  elif layout == "mono":
    outputLayout.nb_channels = 1
    outputLayout.order = 0
    outputLayout.u.mask = 1 # AV_CH_LAYOUT_MONO
  else:
    error "Unsupported audio layout: " & layout

  result.outputLayout = outputLayout

proc init*(resampler: AudioResampler, inputLayout: AVChannelLayout,
    inputFormat: AVSampleFormat, inputRate: int) =
  discard av_opt_set_chlayout(resampler.swrCtx, "in_chlayout",
      unsafeAddr inputLayout, 0)
  discard av_opt_set_sample_fmt(resampler.swrCtx, "in_sample_fmt", inputFormat, 0)
  discard av_opt_set_int(resampler.swrCtx, "in_sample_rate", inputRate, 0)

  discard av_opt_set_chlayout(resampler.swrCtx, "out_chlayout",
      unsafeAddr resampler.outputLayout, 0)
  discard av_opt_set_sample_fmt(resampler.swrCtx, "out_sample_fmt",
      resampler.outputFormat, 0)
  discard av_opt_set_int(resampler.swrCtx, "out_sample_rate",
      resampler.outputSampleRate, 0)

  if swr_init(resampler.swrCtx) < 0:
    error "Failed to initialize audio resampler"

proc resample*(resampler: AudioResampler, frame: ptr AVFrame): seq[ptr uint8] =
  var outputData: ptr uint8
  let outputSamples = swr_convert(resampler.swrCtx, addr outputData, frame.nb_samples,
                                  cast[ptr ptr uint8](addr frame.data[0]),
                                      frame.nb_samples)
  if outputSamples < 0:
    error "Failed to resample audio"

  # Return the converted audio data
  result = @[outputData]

proc close*(resampler: AudioResampler) =
  if resampler.swrCtx != nil:
    swr_free(addr resampler.swrCtx)

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

  # The buffer sink will output in the same format as input by default

  # Create and link filters manually
  var currentFilter = bufferSrc
  var needsFilters = false

  if clip.speed != 1.0:
    needsFilters = true
    # Clamp speed to atempo filter's valid range [0.5 100.0]
    let clampedSpeed = max(0.5, min(100.0, clip.speed))
    var atempoFilter: ptr AVFilterContext = nil
    ret = avfilter_graph_create_filter(addr atempoFilter, avfilter_get_by_name("atempo"),
                                      "atempo", nil, nil, filterGraph)
    if ret < 0:
      error fmt"Cannot create atempo filter: {ret}"
    
    ret = av_opt_set(atempoFilter, "tempo", cstring($clampedSpeed), AV_OPT_SEARCH_CHILDREN)
    if ret < 0:
      error fmt"Cannot set atempo tempo parameter: {ret}"
    
    ret = avfilter_link(currentFilter, 0, atempoFilter, 0)
    if ret < 0:
      error fmt"Cannot link atempo filter: {ret}"
    
    currentFilter = atempoFilter

  # Handle volume changes
  if clip.volume != 1.0:
    needsFilters = true
    var volumeFilter: ptr AVFilterContext = nil
    ret = avfilter_graph_create_filter(addr volumeFilter, avfilter_get_by_name("volume"),
                                      "volume", nil, nil, filterGraph)
    if ret < 0:
      error fmt"Cannot create volume filter: {ret}"

    # Set the volume parameter
    ret = av_opt_set(volumeFilter, "volume", cstring($clip.volume), AV_OPT_SEARCH_CHILDREN)
    if ret < 0:
      error fmt"Cannot set volume parameter: {ret}"

    ret = avfilter_link(currentFilter, 0, volumeFilter, 0)
    if ret < 0:
      error fmt"Cannot link volume filter: {ret}"

    currentFilter = volumeFilter

  # Connect final filter to sink
  ret = avfilter_link(currentFilter, 0, bufferSink, 0)
  if ret < 0:
    error fmt"Cannot link to buffer sink: {ret}"

  # Configure the filter graph
  ret = avfilter_graph_config(filterGraph, nil)
  if ret < 0:
    error fmt"Could not configure audio filter graph: {ret}"

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
  var outputCtx: ptr AVFormatContext
  if avformat_alloc_output_context2(addr outputCtx, nil, "wav", outputPath.cstring) < 0:
    error "Could not create output context"
  defer:
    outputCtx.close()

  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    if avio_open(addr outputCtx.pb, outputPath.cstring, AVIO_FLAG_WRITE) < 0:
      error fmt"Could not open output file '{outputPath}'"

  # Create audio stream BEFORE encoder setup
  let stream = avformat_new_stream(outputCtx, nil)
  if stream == nil:
    error "Could not create audio stream"

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
  discard avcodec_parameters_from_context(stream.codecpar, encoderCtx)

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"

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

proc mixAudioFiles*(sr: int, audioPaths: seq[string], outputPath: string) =
  # This is a simplified mixing function
  # In a full implementation, you'd properly decode each file and mix the samples

  if audioPaths.len == 0:
    error "No audio files to mix"

  if audioPaths.len == 1:
    # Just copy the single file
    copyFile(audioPaths[0], outputPath)
    return

  # For now, just copy the first file as a placeholder
  # In a full implementation, you'd:
  # 1. Decode all audio files
  # 2. Mix the samples together
  # 3. Encode the result
  copyFile(audioPaths[0], outputPath)

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
