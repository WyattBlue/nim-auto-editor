import os
import osproc
import strutils
import std/memfiles
import std/tempfiles
import std/streams
import std/strformat

type
  Args = object
    my_input: string
    ff_loc: string
    time_base: int
    stream: int

  WavContainer = object
    start: uint64
    size: uint64
    bytes_per_sample: uint32
    block_align: uint16
    channels: uint16
    sr: uint32

func mergeUInt32sLE(a: uint32, b: uint32): uint64 =
  # Note: swap `a` and `b` for big endianness
  (uint64(b) shl 32) or uint64(a)

proc error(msg: string) =
  stderr.writeLine(&"Error! {msg}")
  system.quit(1)

proc vanparse(args: seq[string]): Args =
  var
    my_args = Args(my_input:"", ff_loc:"ffmpeg", time_base:30, stream:0)
    arg: string
    i = 1

  if len(args) == 0:
    echo "Display loudness over time"
    system.quit(1)

  while i < len(args):
    arg = args[i]

    if arg == "--help" or arg == "-h":
      echo """Usage: [file ...] [options]

Options:
  --edit METHOD:[ATTRS?]            Select the kind of detection to analyze
                                    with attributes
  -tb, --timebase NUM               Set custom timebase
  --ffmpeg-location                 Point to your custom ffmpeg file
  -h, --help                        Show info about this program then exit
"""
      system.quit(1)

    elif arg == "--ffmpeg-location":
      my_args.ff_loc = args[i+1]
      i += 1
    elif arg == "--edit":
      if not args[i+1].startswith("audio:"):
        error("`--edit` only supports audio method")

      my_args.stream = parseInt(args[i+1][6 .. ^1])
      i += 1
    elif arg == "--timebase" or arg == "-tb":
      my_args.time_base = parseInt(args[i+1])
      if my_args.time_base < 1:
        error("timebase must be greater than 0")
      i += 1
    elif my_args.my_input != "":
      error("Only one file allowed")
    else:
      my_args.my_input = arg

    i += 1

  if my_args.my_input == "":
    error("Input file required")
  return my_args


proc read(filename: string): WavContainer =
  let stream = newFileStream(filename, mode=fmRead)
  defer: stream.close()

  var
    file_sig: array[4, char]
    heading: array[12, char]

  discard stream.readData(file_sig.addr, 4)
  if unlikely(file_sig != ['R', 'F', '6', '4']):
    error(&"File format {repr(file_sig)} not supported.")

  discard stream.readData(heading.addr, 12)
  if unlikely(heading != ['\xFF', '\xFF', '\xFF', '\xFF', 'W', 'A', 'V', 'E', 'd', 's', '6', '4']):
    error(&"Invalid heading for rf64 chunk: {repr(heading)}")

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
    bytes_read: uint

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
      error("Unexpected end of file.")
    if unlikely(len(chunk_id) < 4 and not fmt_chunk_received):
      error(&"Incomplete chunk ID: {repr(chunk_id)}")

    if chunk_id == ['f', 'm', 't', ' ']:
      fmt_chunk_received = true
      discard stream.readData(fmt_size.addr, 4)
      if unlikely(fmt_size < 16):
        error("Binary structure of wave file is not compliant")

      format_tag = stream.readUint16()
      channels = stream.readUint16()
      sr = stream.readUint32()
      bitrate = stream.readUint32()
      block_align = stream.readUint16()
      bit_depth = stream.readUint16()
      bytes_read = 16

      if format_tag == 0xFFFE and fmt_size >= 18:
        let ext_chunk_size = stream.readUint16()
        bytes_read += 2
        if unlikely(ext_chunk_size < 22):
          error("Binary structure of wave file is not compliant")

        stream.setPosition(stream.getPosition() + 6)
        var raw_guid: array[16, char]
        discard stream.readData(raw_guid.addr, 16)
        bytes_read += 22

        if raw_guid[4 .. ^1] == ['\x00', '\x00', '\x10', '\x00', '\x80', '\x00', '\x00', '\xAA', '\x00', '\x38', '\x9B', '\x71']:
          format_tag = cast[uint16](raw_guid[0])

      if unlikely(format_tag != 0x0001 and format_tag != 0x0003):
        error(&"Encountered unknown format tag: {format_tag}, while reading fmt chunk.")

      # move file pointer to next chunk
      if fmt_size > bytes_read:
        stream.setPosition(stream.getPosition() + int(fmt_size - bytes_read))

    elif chunk_id == ['d', 'a', 't', 'a']:
      if unlikely(not fmt_chunk_received):
        error("No fmt chunk before data")

      fake_size = stream.readUint32()
      bytes_per_sample = block_align div channels
      n_samples = data_size div bytes_per_sample

      if bytes_per_sample == 3 or bytes_per_sample == 5 or bytes_per_sample == 7 or bytes_per_sample == 9:
        error(&"Unsupported bytes per sample: {bytes_per_sample}")

      if format_tag == 0x0003 and (not (bytes_per_sample == 4 or bytes_per_sample == 8)):
        error(&"Unsupported bytes per sample: {bytes_per_sample}")

      return WavContainer(
        start:uint64(stream.getPosition()), size:n_samples,
        bytes_per_sample:bytes_per_sample, block_align:block_align,
        channels:channels, sr:sr
      )
    else:
      # Skip unknown chunk
      fake_size = stream.readUint32()
      if unlikely(fake_size == 0):
        error("Unknown chunk")
      stream.setPosition(stream.getPosition() + int(fake_size))
  error(&"No data chunk! {chunk_id}")


proc levels(osargs: seq[string]) =
  let
    args = vanparse(osargs)
    my_input = args.my_input
    time_base = args.time_base
    dir = createTempDir("tmp", "")
    temp_file = joinPath(dir, "out.wav")


  discard execProcess(args.ff_loc,
    args=["-hide_banner", "-y", "-i", my_input, "-map", &"0:a:{args.stream}", "-rf64", "always", temp_file],
    options={poUsePath}
  )

  var
    wav: WavContainer = read(temp_file)
    mm = memfiles.open(temp_file, mode=fmRead)
    thres: seq[float64] = @[]

  let samp_per_ticks = wav.sr div uint64(time_base) * wav.channels

  if wav.bytes_per_sample != 2:
    raise newException(IOError, "Expects int16 only")

  var
    samp: int16
    max_volume: int16 = 0
    local_max: int16 = 0
    local_maxs: seq[int16] = @[]

  for i in wav.start ..< wav.start + wav.size:
    # https://forum.nim-lang.org/t/2132
    samp = cast[ptr int16](cast[uint64](mm.mem) + wav.bytes_per_sample * i)[]

    if samp > max_volume:
      max_volume = samp
    elif samp == low(int16):
      max_volume = high(int16)
    elif -samp > max_volume:
      max_volume = -samp

    if samp > local_max:
      local_max = samp
    elif samp == low(int16):
      local_max = high(int16)
    elif -samp > local_max:
      local_max = -samp

    if i != wav.start and (i - wav.start) mod samp_per_ticks == 0:
      local_maxs.add(local_max)
      local_max = 0

  if unlikely(max_volume == 0):
    for _ in local_maxs:
      thres.add(0)
  else:
    for lo in local_maxs:
      thres.add(lo / max_volume)

  if defined(windows):
    var i = 0
    var buf = "\r\n@start"
    for t in thres:
      buf &= &"{t:.20f}"
      i += 1
      if i > 4000:
        stdout.writeLine(buf)
        stdout.flushFile()
        buf = ""
        i = 0
    
    stdout.writeLine(buf)
    stdout.flushFile()
  else:
    echo "\n@start"
    for t in thres:
      echo &"{t:.20f}"
    echo ""

  mm.close()
  removeDir(dir)

export levels
