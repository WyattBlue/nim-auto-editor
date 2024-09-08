import ffmpeg

type
  AudioFifo* = ref object
    fifo: ptr AVAudioFifo
    sampleFormat: AVSampleFormat
    channels: cint

proc newAudioFifo*(sampleFormat: AVSampleFormat, channels: cint): AudioFifo =
  result = AudioFifo(
    fifo: av_audio_fifo_alloc(sampleFormat, channels, 1),
    sampleFormat: sampleFormat,
    channels: channels
  )
  if result.fifo == nil:
    raise newException(IOError, "Failed to allocate AudioFifo")

proc `=destroy`*(fifo: var AudioFifo) =
  if fifo.fifo != nil:
    av_audio_fifo_free(fifo.fifo)
    fifo.fifo = nil

proc write*(fifo: AudioFifo, data: pointer, size: cint): cint =
  result = av_audio_fifo_write(fifo.fifo, data, size)
  if result < 0:
    raise newException(IOError, "Failed to write to AudioFifo")

proc read*(fifo: AudioFifo, data: pointer, size: cint): cint =
  result = av_audio_fifo_read(fifo.fifo, data, size)
  if result < 0:
    raise newException(IOError, "Failed to read from AudioFifo")

proc samples*(fifo: AudioFifo): cint =
  result = av_audio_fifo_size(fifo.fifo)

proc drain*(fifo: AudioFifo) =
  discard av_audio_fifo_drain(fifo.fifo, av_audio_fifo_size(fifo.fifo))

proc reset*(fifo: AudioFifo) =
  av_audio_fifo_reset(fifo.fifo)
