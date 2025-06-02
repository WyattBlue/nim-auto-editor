import ../ffmpeg
import ../av


proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Dump text-based subtitles to stdout with formatting stripped out"
    quit(0)

  av_log_set_level(AV_LOG_QUIET)

  let packet = av_packet_alloc()
  if packet == nil:
    quit(1)
  defer: av_packet_free(addr packet)

  for inputFile in args:
    var container = av.open(inputFile)
    defer: container.close()
    let formatContext = container.formatContext

    var subStreams: seq[int] = @[]

    for i in 0..<formatContext.nb_streams.int:
      if formatContext.streams[i].codecpar.codecType == AVMEDIA_TYPE_SUBTITLE:
        subStreams.add i

    for i, s in subStreams.pairs:
      let codecName = $avcodec_get_name(formatContext.streams[s].codecpar.codec_id)
      echo "file: " & inputFile & " (" & $i & ":" & codecName & ")"

      let subtitleStream = formatContext.streams[s]
      let codec = avcodec_find_decoder(subtitleStream.codecpar.codec_id)
      if codec == nil:
        continue

      let codecContext = avcodec_alloc_context3(codec)
      if codecContext == nil:
        continue
      defer: avcodec_free_context(addr codecContext)

      if avcodec_parameters_to_context(codecContext, subtitleStream.codecpar) < 0:
        continue
      if avcodec_open2(codecContext, codec, nil) < 0:
        continue

      var subtitle: AVSubtitle

      while av_read_frame(formatContext, packet) >= 0:
        defer: av_packet_unref(packet)

        if packet.stream_index == s.cint:
          var gotSubtitle: cint = 0
          let ret = avcodec_decode_subtitle2(codecContext, addr subtitle, addr gotSubtitle, packet)

          if ret >= 0 and gotSubtitle != 0:
            defer: avsubtitle_free(addr subtitle)
            for i in 0..<subtitle.num_rects:
              let rect = subtitle.rects[i]
              if rect.`type` == SUBTITLE_ASS and rect.ass != nil:
                echo $rect.ass

    echo "------"