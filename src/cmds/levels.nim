import ../av
import ../ffmpeg
import ../log

proc process_audio_frame(frame: ptr AVFrame) =
  echo prettyAudioFrame(frame)

proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Display loudness over time"
    quit(0)

  av_log_set_level(AV_LOG_QUIET)

  let inputFile = args[0]

  var container = av.open(inputFile)
  defer: container.close()

  let formatCtx = container.formatContext

  if container.audio.len == 0:
    error "No audio stream"

  let audioStream: ptr AVStream = container.audio[0].myPtr
  let audioIndex: cint = audioStream.index

  let codec: ptr AVCodec = avcodec_find_decoder(audioStream.codecpar.codec_id)
  if codec == nil:
    error "Decoder not found"

  let codecCtx = avcodec_alloc_context3(codec);
  if codecCtx == nil:
    error "Could not allocate decoder ctx"

  discard avcodec_parameters_to_context(codecCtx, audioStream.codecpar)
  if avcodec_open2(codecCtx, codec, nil) < 0:
    error "Could not open codec\n"

  var packet = av_packet_alloc()
  var frame = av_frame_alloc()
  if packet == nil or frame == nil:
    error "Could not allocate packet/frame"

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

        process_audio_frame(frame)

  # Flush decoder
  discard avcodec_send_packet(codecCtx, nil);
  while avcodec_receive_frame(codecCtx, frame) >= 0:
    process_audio_frame(frame)
