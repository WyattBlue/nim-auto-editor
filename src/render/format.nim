import std/strformat

import ../log
import ../timeline
import ../[av, ffmpeg]

proc makeMedia*(tl: v3, output: var string) =
  var ret: cint
  var container: InputContainer

  var inputPath = "example.mp4"
  var output = "example_ALTERED.wav"
  try:
    container = av.open(inputPath)
  except OSError as e:
    error e.msg
  defer: container.close()

  let inputCtx: ptr AVFormatContext = container.formatContext

  if container.audio.len == 0:
    error "No audio streams"

  let inputStream: ptr AVStream = container.audio[0]
  let audioStreamIdx = inputStream.index

  let decoderCtx = initDecoder(inputStream.codecpar)
  defer: avcodec_free_context(addr decoderCtx)

  let outputCtx: ptr AVFormatContext = nil
  ret = avformat_alloc_output_context2(addr outputCtx, nil, "wav", output.cstring)
  if outputCtx == nil:
    error "Could not create output context"

  if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
    ret = avio_open(addr outputCtx.pb, output.cstring, AVIO_FLAG_WRITE)
    if ret < 0:
      error fmt"Could not open output file '{output}'"

  if avformat_write_header(outputCtx, nil) < 0:
    error "Error occurred when opening output file"

  let (encoder, encoderCtx) = initEncoder("pcm_s16le")
  encoderCtx.sample_rate = decoderCtx.sample_rate
  encoderCtx.ch_layout = decoderCtx.ch_layout
  encoderCtx.sample_fmt = AV_SAMPLE_FMT_S16
  encoderCtx.bit_rate = 0
  encoderCtx.time_base = AVRational(num: 1, den: decoderCtx.sample_rate)
  if avcodec_open2(encoderCtx, encoder, nil) < 0:
    error "Could not open encoder"
  defer: avcodec_free_context(addr encoderCtx)


  discard av_write_trailer(outputCtx)

  if outputCtx != nil:
    if (outputCtx.oformat.flags and AVFMT_NOFILE) == 0:
      discard avio_closep(addr outputCtx.pb)
    avformat_free_context(outputCtx)


  error "Sorry, media rendering isn't implemented yet."
