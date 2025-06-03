import std/sets
import std/options
import std/os
import std/tables
import std/strformat
from std/math import round

import ffmpeg
import media
import log

type v1* = object
  chunks*: seq[(int64, int64, float64)]
  source*: string

type Clip* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

type v3* = object
  tb*: AVRational
  background*: string
  sr*: int64
  layout*: string
  res*: (int64, int64)
  v*: seq[seq[Clip]]
  a*: seq[seq[Clip]]
  chunks*: Option[seq[(int64, int64, float64)]]


func len*(self: v3): int64 =
  result = 0
  for clips in self.v:
    if len(clips) > 0:
      result = max(result, clips[^1].start + clips[^1].dur)
  for clips in self.a:
    if len(clips) > 0:
      result = max(result, clips[^1].start + clips[^1].dur)

func uniqueSources*(self: v3): HashSet[ptr string] =
  for vlayer in self.v:
    for video in vlayer:
      result.incl(video.src)

  for alayer in self.a:
    for audio in alayer:
      result.incl(audio.src)

func toNonLinear*(src: ptr string, tb: AvRational, mi: MediaInfo, chunks: seq[(
    int64, int64, float64)]): v3 =
  var clips: seq[Clip] = @[]
  var i: int64 = 0
  var start: int64 = 0
  var dur: int64
  var offset: int64

  for chunk in chunks:
    if chunk[2] > 0 and chunk[2] < 99999.0:
      dur = int64(round(float64(chunk[1] - chunk[0]) / chunk[2]))
      if dur == 0:
        continue

      offset = int64(float64(chunk[0]) / chunk[2])

      if not (clips.len > 0 and clips[^1].start == start):
        clips.add(Clip(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2]))
      start += dur
      i += 1

  var vspace: seq[seq[Clip]] = @[]
  var aspace: seq[seq[Clip]] = @[]

  if mi.v.len > 0:
    var vlayer: seq[Clip] = @[]
    for clip in clips:
      var videoClip = clip
      videoClip.stream = 0
      vlayer.add(videoClip)
    vspace.add(vlayer)

  for i in 0 ..< mi.a.len:
    var alayer: seq[Clip] = @[]
    for clip in clips:
      var audioClip = clip
      audioClip.stream = i
      alayer.add(audioClip)
    aspace.add(alayer)

  result = v3(v: vspace, a: aspace, chunks: some(chunks))
  result.background = "#000000"
  result.tb = tb
  result.res = mi.get_res()
  result.sr = 48000
  result.layout = "stereo"
  if mi.a.len > 0:
    result.sr = mi.a[0].sampleRate
    result.layout = mi.a[0].layout


proc stem(path: string): string =
  splitFile(path).name


proc mux(inputPath: string, outputPath: string, streamIndex: int64) =
  var
    inputCtx: ptr AVFormatContext = nil
    outputCtx: ptr AVFormatContext = nil
    decoderCtx: ptr AVCodecContext = nil
    encoderCtx: ptr AVCodecContext = nil
    inputStream: ptr AVStream = nil
    outputStream: ptr AVStream = nil
    audioStreamIdx = -1
    currentAudioStream = 0
    ret: cint

  if avformat_open_input(addr inputCtx, inputPath.cstring, nil, nil) < 0:
    error fmt"Could not open input file '{inputPath}'"

  if avformat_find_stream_info(inputCtx, nil) < 0:
    error "Could not find stream information"

  # Find the specified audio stream
  for i in 0..<inputCtx.nb_streams:
    if inputCtx.streams[i].codecpar.codec_type == AVMEDIA_TYPE_AUDIO:
      if currentAudioStream == streamIndex:
        audioStreamIdx = i.cint
        break
      inc currentAudioStream

  if audioStreamIdx == -1:
    error fmt"Could not find audio stream at index {streamIndex}"

  inputStream = inputCtx.streams[audioStreamIdx]

  let decoder = avcodec_find_decoder(inputStream.codecpar.codec_id)
  if decoder == nil:
    error "Could not find decoder"

  decoderCtx = avcodec_alloc_context3(decoder)
  if decoderCtx == nil:
    error "Could not allocate decoder context"

  if avcodec_parameters_to_context(decoderCtx, inputStream.codecpar) < 0:
    error "Could not copy decoder parameters"

  if avcodec_open2(decoderCtx, decoder, nil) < 0:
    error "Could not open decoder"

  ret = avformat_alloc_output_context2(addr outputCtx, nil, nil, outputPath.cstring)
  if outputCtx == nil:
    error "Could not create output context"

  let encoder = avcodec_find_encoder(AV_CODEC_ID_PCM_S16LE)
  if encoder == nil:
    error "Could not find PCM encoder"

  encoderCtx = avcodec_alloc_context3(encoder)
  if encoderCtx == nil:
    error "Could not allocate encoder context"

  # Set encoder parameters
  encoderCtx.codec_type = AVMEDIA_TYPE_AUDIO
  encoderCtx.sample_rate = decoderCtx.sample_rate
  encoderCtx.ch_layout = decoderCtx.ch_layout
  encoderCtx.sample_fmt = AV_SAMPLE_FMT_S16
  encoderCtx.bit_rate = 0  # PCM doesn't need bitrate

  ret = avcodec_open2(encoderCtx, encoder, nil)
  if ret < 0:
    error "Could not open encoder"

  # Add stream to output format
  outputStream = avformat_new_stream(outputCtx, nil)
  if outputStream == nil:
    error "Could not allocate output stream"

  if avcodec_parameters_from_context(outputStream.codecpar, encoderCtx) < 0:
    error "Could not copy encoder parameters"

  # Open output file
  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    ret = avio_open(addr outputCtx.pb, outputPath.cstring, AVIO_FLAG_WRITE)
    if ret < 0:
      echo fmt"Could not open output file '{outputPath}'"
      avcodec_free_context(addr encoderCtx)
      avformat_free_context(outputCtx)
      avcodec_free_context(addr decoderCtx)
      avformat_close_input(addr inputCtx)
      return

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"

  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  if packet == nil or frame == nil:
    error "Could not allocate packet or frame"

  # Read and process frames
  while av_read_frame(inputCtx, packet) >= 0:
    if packet.stream_index == audioStreamIdx:

      if avcodec_send_packet(decoderCtx, packet) < 0:
        error "Error sending packet to decoder"

      while ret >= 0:
        ret = avcodec_receive_frame(decoderCtx, frame)
        if ret == AVERROR(EAGAIN) or ret == AVERROR_EOF:
          break
        elif ret < 0:
          echo "Error during decoding"
          break

        # Encode frame
        ret = avcodec_send_frame(encoderCtx, frame)
        if ret < 0:
          echo "Error sending frame to encoder"
          break

        while ret >= 0:
          var outPacket = av_packet_alloc()
          ret = avcodec_receive_packet(encoderCtx, outPacket)
          if ret == AVERROR(EAGAIN) or ret == AVERROR_EOF:
            av_packet_free(addr outPacket)
            break
          elif ret < 0:
            echo "Error during encoding"
            av_packet_free(addr outPacket)
            break

          outPacket.stream_index = outputStream.index
          av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)

          ret = av_interleaved_write_frame(outputCtx, outPacket)
          av_packet_free(addr outPacket)
          if ret < 0:
            error "Error muxing packet"

    av_packet_unref(packet)

  # Flush decoder
  ret = avcodec_send_packet(decoderCtx, nil)
  if ret >= 0:
    while ret >= 0:
      ret = avcodec_receive_frame(decoderCtx, frame)
      if ret == AVERROR_EOF:
        break
      elif ret < 0:
        break

      # Encode remaining frames
      ret = avcodec_send_frame(encoderCtx, frame)
      if ret < 0: break

      while ret >= 0:
        var outPacket = av_packet_alloc()
        ret = avcodec_receive_packet(encoderCtx, outPacket)
        if ret == AVERROR(EAGAIN) or ret == AVERROR_EOF:
          av_packet_free(addr outPacket)
          break
        elif ret < 0:
          av_packet_free(addr outPacket)
          break

        outPacket.stream_index = outputStream.index
        av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)

        discard av_interleaved_write_frame(outputCtx, outPacket)
        av_packet_free(addr outPacket)

  # Flush encoder
  ret = avcodec_send_frame(encoderCtx, nil)
  if ret >= 0:
    while ret >= 0:
      var outPacket = av_packet_alloc()
      ret = avcodec_receive_packet(encoderCtx, outPacket)
      if ret == AVERROR_EOF:
        av_packet_free(addr outPacket)
        break
      elif ret < 0:
        av_packet_free(addr outPacket)
        break

      outPacket.stream_index = outputStream.index
      av_packet_rescale_ts(outPacket, encoderCtx.time_base, outputStream.time_base)

      discard av_interleaved_write_frame(outputCtx, outPacket)
      av_packet_free(addr outPacket)

  discard av_write_trailer(outputCtx)

  if packet != nil: av_packet_free(addr packet)
  if frame != nil: av_frame_free(addr frame)
  if decoderCtx != nil: avcodec_free_context(addr decoderCtx)
  if encoderCtx != nil: avcodec_free_context(addr encoderCtx)
  if inputCtx != nil: avformat_close_input(addr inputCtx)
  if outputCtx != nil:
    if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
      discard avio_closep(addr outputCtx.pb)
    avformat_free_context(outputCtx)


proc setStreamTo0*(tl: var v3, interner: var StringInterner) =
  var dirExists = false
  var cache = initTable[string, MediaInfo]()

  proc makeTrack(i: int64, path: string): MediaInfo =
    let folder: string = path.parentDir / (path.stem & "_tracks")
    if not dirExists:
      try:
        createDir(folder)
      except OSError:
        removeDir(folder)
        createDir(folder)
      dirExists = true

    let newtrack: string = folder / (path.stem & "_" & $i & ".wav")
    if newtrack notin cache:
      mux(path, newtrack, i)
      cache[newtrack] = initMediaInfo(newtrack)
    return cache[newtrack]

  for layer in tl.a.mitems:
    for clip in layer.mitems:
      if clip.stream > 0:
        let mi = makeTrack(clip.stream, clip.src[])
        clip.src = interner.intern(mi.path)
        clip.stream = 0
