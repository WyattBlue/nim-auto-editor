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

proc newAudioResampler*(format: AVSampleFormat, layout: string, rate: int): AudioResampler =
  result = new(AudioResampler)
  result.swrCtx = swr_alloc()
  result.outputFormat = format
  result.outputSampleRate = rate

  # Set up output channel layout
  var outputLayout: AVChannelLayout
  if layout == "stereo":
    outputLayout.nb_channels = 2
    outputLayout.order = 0
    outputLayout.u.mask = 3  # AV_CH_LAYOUT_STEREO
  elif layout == "mono":
    outputLayout.nb_channels = 1
    outputLayout.order = 0
    outputLayout.u.mask = 1  # AV_CH_LAYOUT_MONO
  else:
    error "Unsupported audio layout: " & layout

  result.outputLayout = outputLayout

proc init*(resampler: AudioResampler, inputLayout: AVChannelLayout, inputFormat: AVSampleFormat, inputRate: int) =
  discard av_opt_set_chlayout(resampler.swrCtx, "in_chlayout", unsafeAddr inputLayout, 0)
  discard av_opt_set_sample_fmt(resampler.swrCtx, "in_sample_fmt", inputFormat, 0)
  discard av_opt_set_int(resampler.swrCtx, "in_sample_rate", inputRate, 0)

  discard av_opt_set_chlayout(resampler.swrCtx, "out_chlayout", unsafeAddr resampler.outputLayout, 0)
  discard av_opt_set_sample_fmt(resampler.swrCtx, "out_sample_fmt", resampler.outputFormat, 0)
  discard av_opt_set_int(resampler.swrCtx, "out_sample_rate", resampler.outputSampleRate, 0)

  if swr_init(resampler.swrCtx) < 0:
    error "Failed to initialize audio resampler"

proc resample*(resampler: AudioResampler, frame: ptr AVFrame): seq[ptr uint8] =
  var outputData: ptr uint8
  let outputSamples = swr_convert(resampler.swrCtx, addr outputData, frame.nb_samples,
                                  cast[ptr ptr uint8](addr frame.data[0]), frame.nb_samples)
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
  let startPts = int64(startTimeInSeconds / (timeBase.num.float / timeBase.den.float))
  
  # Seek to the approximate position
  if av_seek_frame(container.formatContext, stream.index, startPts, AVSEEK_FLAG_BACKWARD) < 0:
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
          let channels = min(frame.ch_layout.nb_channels.int, 2)  # Limit to stereo
          let samples = frame.nb_samples.int

          # Convert frame PTS to sample position
          let frameSamplePos = if frame.pts != AV_NOPTS_VALUE:
            int64(frame.pts.float * timeBase.num.float / timeBase.den.float * sampleRate.float)
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
                  result[ch][totalSamples + i] = audioData[frameIndex * channels + ch]
              
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
    for i in 0..<min(100, result[1].len):  # Check first 100 samples
      if result[1][i] != 0:
        isSecondChannelEmpty = false
        break
    
    if isSecondChannelEmpty:
      # Copy first channel to second for stereo output
      for i in 0..<result[0].len:
        result[1][i] = result[0][i]

proc processAudioClip*(clip: Clip, data: seq[seq[int16]], sr: int): seq[seq[int16]] =
  # This is a simplified version - in a full implementation you'd use libavfilter
  # for speed and volume changes

  result = data

  # Apply volume change
  if clip.volume != 1.0:
    for ch in 0..<result.len:
      for i in 0..<result[ch].len:
        result[ch][i] = int16(result[ch][i].float * clip.volume)

  # Speed change would require more complex resampling
  # For now, we'll just return the data as-is
  # In a full implementation, you'd use the atempo filter

proc ndArrayToFile*(audioData: seq[seq[int16]], rate: int, outputPath: string) =
  var outputCtx: ptr AVFormatContext
  if avformat_alloc_output_context2(addr outputCtx, nil, "wav", outputPath.cstring) < 0:
    error "Could not create output context"
  defer:
    if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
      discard avio_closep(addr outputCtx.pb)
    avformat_free_context(outputCtx)

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
    encoderCtx.ch_layout.u.mask = 1  # AV_CH_LAYOUT_MONO
  else:
    encoderCtx.ch_layout.u.mask = 3  # AV_CH_LAYOUT_STEREO
  encoderCtx.sample_fmt = AV_SAMPLE_FMT_S16  # Use interleaved format
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
    let samplesPerFrame = 1024  # Process in chunks of 1024 samples
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

  discard av_write_trailer(outputCtx)

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
  # This is a simplified version of the audio processing
  # In a full implementation, you'd process each audio layer

  result = @[]
  var samples: Table[(string, int32), Getter]

  # If no audio layers, return empty
  if tl.a.len == 0:
    return result

  for i, layer in tl.a:
    if layer.len == 0:
      continue

    conwrite("Creating audio")

    for clip in layer:
      let key = (clip.src[], clip.stream)
      if key notin samples:
        samples[key] = newGetter(clip.src[], clip.stream.int, tl.sr.int)

    # Create output file for this layer
    let outputPath = outputDir / fmt"audio_layer_{i}.wav"

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
        let getter = samples[key]

        # Calculate sample positions
        let startSample = int(clip.start * tl.sr.int64 * tl.tb.den div tl.tb.num)
        let durSamples = int(clip.dur * tl.sr.int64 * tl.tb.den div tl.tb.num)

        # Get audio data from source
        let srcStartSample = int(clip.offset * tl.sr.int64 * tl.tb.den div tl.tb.num)
        let srcEndSample = srcStartSample + durSamples

        try:
          let srcData = getter.get(srcStartSample, srcEndSample)

          # Process the clip (apply volume, etc.)
          let processedData = processAudioClip(clip, srcData, tl.sr.int)

          # Mix into output
          if processedData.len > 0:
            for ch in 0..<min(audioData.len, processedData.len):
              for i in 0..<min(durSamples, processedData[ch].len):
                let outputIndex = startSample + i
                if outputIndex < audioData[ch].len:
                  # Mix audio by adding with proper overflow protection
                  let currentSample = audioData[ch][outputIndex].int32
                  let newSample = processedData[ch][i].int32
                  let mixed = currentSample + newSample
                  # Clamp to 16-bit range to prevent overflow distortion
                  audioData[ch][outputIndex] = int16(max(-32768, min(32767, mixed)))
        except:
          # If we can't read the source, that segment remains silent
          discard

    # Write the processed audio to file
    result.add(outputPath)
    ndArrayToFile(audioData, tl.sr.int, outputPath)

  # Close all getters
  for getter in samples.values:
    getter.close()

#[ Python version for reference:

from __future__ import annotations

from fractions import Fraction
from io import BytesIO
from pathlib import Path
from typing import TYPE_CHECKING, cast

import bv
import numpy as np
from bv import AudioFrame

from auto_editor.ffwrapper import FileInfo
from auto_editor.lib.err import MyError
from auto_editor.timeline import Clip, v3
from auto_editor.utils.func import parse_bitrate
from auto_editor.utils.log import Log

if TYPE_CHECKING:
    from collections.abc import Iterator

    from auto_editor.__main__ import Args



def process_audio_clip(clip: Clip, data: np.ndarray, sr: int, log: Log) -> np.ndarray:
    to_s16 = bv.AudioResampler(format="s16", layout="stereo", rate=sr)
    input_buffer = BytesIO()

    with bv.open(input_buffer, "w", format="wav") as container:
        output_stream = container.add_stream(
            "pcm_s16le", sample_rate=sr, format="s16", layout="stereo"
        )

        frame = AudioFrame.from_ndarray(data, format="s16p", layout="stereo")
        frame.rate = sr

        for reframe in to_s16.resample(frame):
            container.mux(output_stream.encode(reframe))
        container.mux(output_stream.encode(None))

    input_buffer.seek(0)

    input_file = bv.open(input_buffer, "r")
    input_stream = input_file.streams.audio[0]

    graph = bv.filter.Graph()
    args = [graph.add_abuffer(template=input_stream)]

    if clip.speed != 1:
        if clip.speed > 10_000:
            for _ in range(3):
                args.append(graph.add("atempo", f"{clip.speed ** (1 / 3)}"))
        elif clip.speed > 100:
            for _ in range(2):
                args.append(graph.add("atempo", f"{clip.speed**0.5}"))
        elif clip.speed >= 0.5:
            args.append(graph.add("atempo", f"{clip.speed}"))
        else:
            start = 0.5
            while start * 0.5 > clip.speed:
                start *= 0.5
                args.append(graph.add("atempo", "0.5"))
            args.append(graph.add("atempo", f"{clip.speed / start}"))

    if clip.volume != 1:
        args.append(graph.add("volume", f"{clip.volume}"))

    args.append(graph.add("abuffersink"))
    graph.link_nodes(*args).configure()

    all_frames = []
    resampler = bv.AudioResampler(format="s16p", layout="stereo", rate=sr)

    for frame in input_file.decode(input_stream):
        graph.push(frame)
        while True:
            try:
                aframe = graph.pull()
                assert isinstance(aframe, AudioFrame)

                for resampled_frame in resampler.resample(aframe):
                    all_frames.append(resampled_frame.to_ndarray())

            except (bv.BlockingIOError, bv.EOFError):
                break

    if not all_frames:
        log.debug(f"No audio frames at {clip=}")
        return np.zeros_like(data)
    return np.concatenate(all_frames, axis=1)


def mix_audio_files(sr: int, audio_paths: list[str], output_path: str) -> None:
    mixed_audio = None
    max_length = 0

    # First pass: determine the maximum length
    for path in audio_paths:
        container = bv.open(path)
        stream = container.streams.audio[0]

        # Calculate duration in samples
        assert stream.duration is not None
        assert stream.time_base is not None
        duration_samples = int(stream.duration * sr / stream.time_base.denominator)
        max_length = max(max_length, duration_samples)
        container.close()

    # Second pass: read and mix audio
    for path in audio_paths:
        container = bv.open(path)
        stream = container.streams.audio[0]

        resampler = bv.audio.resampler.AudioResampler(
            format="s16", layout="mono", rate=sr
        )

        audio_array: list[np.ndarray] = []
        for frame in container.decode(audio=0):
            frame.pts = None
            resampled = resampler.resample(frame)[0]
            audio_array.extend(resampled.to_ndarray().flatten())

        # Pad or truncate to max_length
        current_audio = np.array(audio_array[:max_length])
        if len(current_audio) < max_length:
            current_audio = np.pad(
                current_audio, (0, max_length - len(current_audio)), "constant"
            )

        if mixed_audio is None:
            mixed_audio = current_audio.astype(np.float32)
        else:
            mixed_audio += current_audio.astype(np.float32)

        container.close()

    if mixed_audio is None:
        raise ValueError("mixed_audio is None")

    # Normalize the mixed audio
    max_val = np.max(np.abs(mixed_audio))
    if max_val > 0:
        mixed_audio = mixed_audio * (32767 / max_val)
    mixed_audio = mixed_audio.astype(np.int16)

    output_container = bv.open(output_path, mode="w")
    output_stream = output_container.add_stream("pcm_s16le", rate=sr)

    chunk_size = sr  # Process 1 second at a time
    for i in range(0, len(mixed_audio), chunk_size):
        # Shape becomes (1, samples) for mono
        chunk = np.array([mixed_audio[i : i + chunk_size]])

        frame = AudioFrame.from_ndarray(chunk, format="s16", layout="mono")
        frame.rate = sr
        frame.pts = i  # Set presentation timestamp

        output_container.mux(output_stream.encode(frame))

    output_container.mux(output_stream.encode(None))
    output_container.close()


def ndarray_to_file(audio_data: np.ndarray, rate: int, out: str | Path) -> None:
    layout = "stereo"

    with bv.open(out, mode="w") as output:
        stream = output.add_stream("pcm_s16le", rate=rate, format="s16", layout=layout)

        frame = bv.AudioFrame.from_ndarray(audio_data, format="s16p", layout=layout)
        frame.rate = rate

        output.mux(stream.encode(frame))
        output.mux(stream.encode(None))


def ndarray_to_iter(
    audio_data: np.ndarray, fmt: bv.AudioFormat, layout: str, rate: int
) -> Iterator[AudioFrame]:
    chunk_size = rate // 4  # Process 0.25 seconds at a time

    resampler = bv.AudioResampler(rate=rate, format=fmt, layout=layout)
    for i in range(0, audio_data.shape[1], chunk_size):
        chunk = audio_data[:, i : i + chunk_size]

        frame = AudioFrame.from_ndarray(chunk, format="s16p", layout="stereo")
        frame.rate = rate
        frame.pts = i

        yield from resampler.resample(frame)


def make_new_audio(
    output: bv.container.OutputContainer,
    audio_format: bv.AudioFormat,
    tl: v3,
    args: Args,
    log: Log,
) -> tuple[list[bv.AudioStream], list[Iterator[AudioFrame]]]:
    audio_inputs = []
    audio_gen_frames = []
    audio_streams: list[bv.AudioStream] = []
    audio_paths = _make_new_audio(tl, audio_format, args, log)

    for i, audio_path in enumerate(audio_paths):
        audio_stream = output.add_stream(
            args.audio_codec,
            rate=tl.sr,
            format=audio_format,
            layout=tl.T.layout,
            time_base=Fraction(1, tl.sr),
        )
        if not isinstance(audio_stream, bv.AudioStream):
            log.error(f"Not a known audio codec: {args.audio_codec}")

        if args.audio_bitrate != "auto":
            audio_stream.bit_rate = parse_bitrate(args.audio_bitrate, log)
            log.debug(f"audio bitrate: {audio_stream.bit_rate}")
        else:
            log.debug(f"[auto] audio bitrate: {audio_stream.bit_rate}")

        if i < len(tl.T.audios) and (lang := tl.T.audios[i].lang) is not None:
            audio_stream.metadata["language"] = lang

        audio_streams.append(audio_stream)

        if isinstance(audio_path, str):
            audio_input = bv.open(audio_path)
            audio_inputs.append(audio_input)
            audio_gen_frames.append(audio_input.decode(audio=0))
        else:
            audio_gen_frames.append(audio_path)

    return audio_streams, audio_gen_frames


class Getter:
    __slots__ = ("container", "stream", "rate")

    def __init__(self, path: Path, stream: int, rate: int):
        self.container = bv.open(path)
        self.stream = self.container.streams.audio[stream]
        self.rate = rate

    def get(self, start: int, end: int) -> np.ndarray:
        # start/end is in samples

        container = self.container
        stream = self.stream
        resampler = bv.AudioResampler(format="s16p", layout="stereo", rate=self.rate)

        time_base = stream.time_base
        assert time_base is not None
        start_pts = int(start / self.rate / time_base)

        # Seek to the approximate position
        container.seek(start_pts, stream=stream)

        all_frames = []
        total_samples = 0
        target_samples = end - start

        # Decode frames until we have enough samples
        for frame in container.decode(stream):
            for resampled_frame in resampler.resample(frame):
                frame_array = resampled_frame.to_ndarray()
                all_frames.append(frame_array)
                total_samples += frame_array.shape[1]

                if total_samples >= target_samples:
                    break

            if total_samples >= target_samples:
                break

        result = np.concatenate(all_frames, axis=1)

        # Trim to exact size
        if result.shape[1] > target_samples:
            result = result[:, :target_samples]
        elif result.shape[1] < target_samples:
            # Pad with zeros if we don't have enough samples
            padding = np.zeros(
                (result.shape[0], target_samples - result.shape[1]), dtype=result.dtype
            )
            result = np.concatenate([result, padding], axis=1)

        assert result.shape[1] == end - start
        return result  # Return NumPy array with shape (channels, samples)


def _make_new_audio(
    tl: v3, fmt: bv.AudioFormat, args: Args, log: Log
) -> list[str | Iterator[AudioFrame]]:
    sr = tl.sr
    tb = tl.tb
    output: list[str | Iterator[AudioFrame]] = []
    samples: dict[tuple[FileInfo, int], Getter] = {}

    if not tl.a[0]:
        log.error("Trying to render empty audio timeline")

    layout = tl.T.layout
    try:
        bv.AudioLayout(layout)
    except ValueError:
        log.error(f"Invalid audio layout: {layout}")

    for i, layer in enumerate(tl.a):
        arr: np.ndarray | None = None
        use_iter = False

        for clip in layer:
            if (clip.src, clip.stream) not in samples:
                samples[(clip.src, clip.stream)] = Getter(
                    clip.src.path, clip.stream, sr
                )

            log.conwrite("Creating audio")
            if arr is None:
                leng = max(round((layer[-1].start + layer[-1].dur) * sr / tb), sr // tb)
                map_path = Path(log.temp, f"{i}.map")
                arr = np.memmap(map_path, mode="w+", dtype=np.int16, shape=(2, leng))

            samp_start = round(clip.offset * clip.speed * sr / tb)
            samp_end = round((clip.offset + clip.dur) * clip.speed * sr / tb)

            getter = samples[(clip.src, clip.stream)]

            if clip.speed != 1 or clip.volume != 1:
                clip_arr = process_audio_clip(
                    clip, getter.get(samp_start, samp_end), sr, log
                )
            else:
                clip_arr = getter.get(samp_start, samp_end)

            # Mix numpy arrays
            start = clip.start * sr // tb
            clip_samples = clip_arr.shape[1]
            if start + clip_samples > arr.shape[1]:
                # Shorten `clip_arr` if bigger than expected.
                arr[:, start:] += clip_arr[:, : arr.shape[1] - start]
            else:
                arr[:, start : start + clip_samples] += clip_arr

        if arr is not None:
            if args.mix_audio_streams:
                path = Path(log.temp, f"new{i}.wav")
                ndarray_to_file(arr, sr, path)
                output.append(f"{path}")
            else:
                use_iter = True

        if use_iter and arr is not None:
            output.append(ndarray_to_iter(arr, fmt, layout, sr))

    if args.mix_audio_streams and len(output) > 1:
        new_a_file = f"{Path(log.temp, 'new_audio.wav')}"
        # When mix_audio_streams is True, output only contains strings
        audio_paths = cast(list[str], output)
        mix_audio_files(sr, audio_paths, new_a_file)
        return [new_a_file]

    return output


]#
