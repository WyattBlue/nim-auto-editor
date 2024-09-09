import ffmpeg
import av
import audio_fifo

proc main*(inputFile: string) =
  var container = av.open(inputFile)
  defer: container.close()

  if container.audio.len == 0:
    echo "No audio streams found in the input file."
    quit(1)

  let audioStream = container.audio[0]
  let codecContext = audioStream.codecContext

  if codecContext == nil:
    echo "Failed to get codec context."
    quit(1)

  let codec = avcodec_find_decoder(codecContext.codec_id)
  if codec == nil:
    echo "Unsupported codec!"
    quit(1)

  # Open the codec
  if avcodec_open2(codecContext, codec, nil) < 0:
    echo "Could not open codec!"
    quit(1)

  defer: discard avcodec_close(codecContext)

  # Create an AudioFifo
  var fifo = newAudioFifo(codecContext.sample_fmt, codecContext.ch_layout.nb_channels)
  if fifo == nil:
    echo "Failed to create AudioFifo."
    quit(1)

  # Allocate a buffer for reading audio samples
  let bufferSize = 1024 * codecContext.ch_layout.nb_channels * av_get_bytes_per_sample(codecContext.sample_fmt)
  var buffer = newSeq[uint8](bufferSize)

  # Read some audio data and write it to the FIFO
  var packet: AVPacket
  var frame: ptr AVFrame = av_frame_alloc()
  defer: av_frame_free(addr frame)

  while av_read_frame(container.formatContext, addr packet) >= 0:
    defer: av_packet_unref(addr packet)

    if packet.stream_index == audioStream.index:
      # Decode audio packet and write to FIFO
      let sendResult = avcodec_send_packet(codecContext, addr packet)
      if sendResult < 0:
        echo "Error sending packet for decoding ", sendResult.int
        continue

      while true:
        let receiveResult = avcodec_receive_frame(codecContext, frame)
        if receiveResult == AVERROR(EAGAIN) or receiveResult == AVERROR_EOF:
          break
        elif receiveResult < 0:
          echo "Error during decoding"
          break

        let dataSize = av_samples_get_buffer_size(
          nil, codecContext.ch_layout.nb_channels, frame.nb_samples, codecContext.sample_fmt, 1
        )
        if frame.data[0] != nil:
          fifo.write(frame.data[0], frame.nb_samples)

        av_frame_unref(frame)

      # Break after reading a few packets for this example
      if fifo.samples > 10000:
        break

  echo "Total samples in FIFO: ", fifo.samples

  # Read data back from the FIFO
  var totalSamplesRead = 0
  while fifo.samples > 0:
    let samplesToRead = min(1024, fifo.samples)
    let bytesToRead = samplesToRead * codecContext.ch_layout.nb_channels * av_get_bytes_per_sample(AVSampleFormat(codecContext.sample_fmt))
    if buffer.len > 0:
      fifo.read(addr buffer[0], samplesToRead)
      totalSamplesRead += samplesToRead

  echo "Total samples read from FIFO: ", totalSamplesRead

  echo "AudioFifo example completed."
