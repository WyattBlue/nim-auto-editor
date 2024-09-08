import ffmpeg
import av
import audio_fifo

proc main*(inputFile: string) =
  var container = av.open(inputFile)
  defer: container.close()

  if container.audio.len == 0:
    echo "No audio streams found in the input file."
    return

  let audioStream = container.audio[0]
  let codecContext = audioStream.codecContext

  # Create an AudioFifo
  var fifo = newAudioFifo(AVSampleFormat(codecContext.sample_fmt), codecContext.ch_layout.nb_channels)

  # Allocate a buffer for reading audio samples
  let bufferSize = 1024 * codecContext.ch_layout.nb_channels * av_get_bytes_per_sample(AVSampleFormat(codecContext.sample_fmt))
  var buffer = newSeq[uint8](bufferSize)

  # Read some audio data and write it to the FIFO
  var packet: AVPacket
  while av_read_frame(container.formatContext, addr packet) >= 0:
    defer: av_packet_unref(addr packet)

    if packet.stream_index == audioStream.index:
      # Decode audio packet and write to FIFO
      var frame: AVFrame
      discard avcodec_send_packet(codecContext, addr packet)
      while avcodec_receive_frame(codecContext, addr frame) >= 0:
        let dataSize = av_samples_get_buffer_size(nil, codecContext.ch_layout.nb_channels,
                                                  frame.nb_samples, AVSampleFormat(codecContext.sample_fmt), 1)
        discard fifo.write(frame.data[0], frame.nb_samples)
        av_frame_unref(addr frame)

      # Break after reading a few packets for this example
      if fifo.samples > 10000:
        break

  echo "Total samples in FIFO: ", fifo.samples

  # Read data back from the FIFO
  var totalSamplesRead = 0
  while fifo.samples > 0:
    let samplesToRead = min(1024, fifo.samples)
    let bytesToRead = samplesToRead * codecContext.ch_layout.nb_channels * av_get_bytes_per_sample(AVSampleFormat(codecContext.sample_fmt))
    discard fifo.read(addr buffer[0], samplesToRead)
    totalSamplesRead += samplesToRead

  echo "Total samples read from FIFO: ", totalSamplesRead

  echo "AudioFifo example completed."
