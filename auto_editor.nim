import os
import osproc
import strutils
import std/memfiles
import std/tempfiles
import std/streams
import std/strformat

func mergeUInt32sLE(a: uint32, b: uint32): uint64 =
  # Note: swap `a` and `b` for big endianness
  (uint64(b) shl 32) or uint64(a)

type
  WavContainer = object
    start: uint64
    size: uint64
    bytes_per_sample: uint32
    block_align: uint16
    channels: uint16
    sr: uint32

proc read(filename: string): WavContainer =
  let stream = newFileStream(filename, mode=fmRead)
  defer: stream.close()

  var
    file_sig: array[4, char]
    heading: array[12, char]

  discard stream.readData(file_sig.addr, 4)
  if unlikely(file_sig != ['R', 'F', '6', '4']):
    raise newException(IOError, &"File format {repr(file_sig)} not supported.")

  discard stream.readData(heading.addr, 12)
  if unlikely(heading != ['\xFF', '\xFF', '\xFF', '\xFF', 'W', 'A', 'V', 'E', 'd', 's', '6', '4']):
    raise newException(IOError, &"Invalid heading for rf64 chunk: {repr(heading)}")

  var
    chunk_size = stream.readUint32()
    bw_size_low = stream.readUint32()
    bw_size_high = stream.readUint32()
    data_size_low = stream.readUint32()
    data_size_high = stream.readUint32()
    fmt_chunk_received = false
    chunk_id: array[4, char]

    # reading fmt
    fmt_size: uint32
    format_tag: uint16
    channels: uint16
    sr: uint32
    bitrate: uint32
    block_align: uint16
    bit_depth: uint16

    # reading data
    fake_size: uint32
    bytes_per_sample: uint32
    n_samples: uint64

  let
    file_size = mergeUInt32sLE(bw_size_low, bw_size_high)
    data_size = mergeUInt32sLE(data_size_low, data_size_high)

  stream.setPosition(stream.getPosition() + (40 - int(chunk_size)))

  while uint64(stream.getPosition()) < file_size:
    discard stream.readData(chunk_id.addr, 4)

    if unlikely(len(chunk_id) == 0):
      raise newException(IOError, "Unexpected end of file.")
    if unlikely(len(chunk_id) < 4 and not fmt_chunk_received):
      raise newException(IOError, &"Incomplete chunk ID: {repr(chunk_id)}")

    if chunk_id == ['f', 'm', 't', ' ']:
      fmt_chunk_received = true
      discard stream.readData(fmt_size.addr, 4)
      if unlikely(fmt_size < 16):
        raise newException(IOError, "Binary structure of wave file is not compliant")

      format_tag = stream.readUint16()
      channels = stream.readUint16()
      sr = stream.readUint32()
      bitrate = stream.readUint32()
      block_align = stream.readUint16()
      bit_depth = stream.readUint16()

      if unlikely(format_tag != 0x0001 and format_tag != 0x0003):
        raise newException(IOError,
          &"Encountered unknown format tag: {format_tag}, while reading fmt chunk."
        )

      # move file pointer to next chunk
      if fmt_size > 16:
        stream.setPosition(stream.getPosition() + int(fmt_size - 16))

    elif chunk_id == ['d', 'a', 't', 'a']:
      if unlikely(not fmt_chunk_received):
        raise newException(IOError, "No fmt chunk before data")

      fake_size = stream.readUint32()
      bytes_per_sample = block_align div channels
      n_samples = data_size div bytes_per_sample

      if bytes_per_sample != 2:
        raise newException(IOError, "only support uint16")

      if format_tag != 0x0001:
        raise newException(IOError, "only supports PCM audio")

      return WavContainer(
        start:uint64(stream.getPosition()), size:n_samples,
        bytes_per_sample:bytes_per_sample, block_align:block_align,
        channels:channels, sr:sr
      )
    else:
      # Skip unknown chunk
      fake_size = stream.readUint32()
      if unlikely(fake_size == 0):
        raise newException(IOError, "Unknown chunk")
      stream.setPosition(stream.getPosition() + int(fake_size))
  raise newException(IOError, "No data chunk!")


let my_args = os.commandLineParams()
const time_base: int = 30

if len(my_args) == 0:
  echo """
Auto-Editor is an automatic video/audio creator and editor. By default, it will detect silence and create a new video with those sections cut out.

Run:
    auto-editor --help

To get the list of options."""
else:
  let
    my_input = my_args[0]
    dir = createTempDir("tmp", "")
    temp_file = joinPath(dir, "out.wav")

  discard execProcess("ffmpeg",
    args=["-hide_banner", "-y", "-i", my_input, "-map", "0:a:0", "-rf64", "always", temp_file],
    options={poUsePath}
  )

  var
    wav: WavContainer = read(temp_file)
    mm = memfiles.open(temp_file, mode=fmRead)
    max_volume: int16 = 0
    samp: int16

  for i in wav.start ..< wav.start + wav.size:
    # https://forum.nim-lang.org/t/2132
    samp = cast[ptr int16](cast[uint64](mm.mem) + 2*i)[]
    if samp > max_volume:
      max_volume = samp
    elif samp < 0 and -samp > max_volume:
      max_volume = -samp

  echo "max_volume ", max_volume
  mm.close()
  removeDir(dir)

