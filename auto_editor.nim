import os
import std/tempfiles
import std/streams
import std/strformat
import osproc
import strutils
import std/memfiles


proc mergeUInt32sLE(a: uint32, b: uint32): uint64 =
  # Note: swap `a` and `b` for big endianness
  (uint64(b) shl 32) or uint64(a)

template toOpenArray(ms: MemSlice, T: typedesc = byte): openArray[T] =
  # template because openArray isn't a valid return type yet
  toOpenArray(cast[ptr UncheckedArray[T]](ms.data), 0, (ms.size div sizeof(T)) - 1)


proc read(filename: string) =
  let stream = newFileStream(filename, mode=fmRead)
  defer: stream.close()

  var file_sig: array[4, char]
  discard stream.readData(file_sig.addr, 4)

  if file_sig == ['R', 'F', '6', '4']:
    var heading: array[12, char]
    discard stream.readData(heading.addr, 12)

    if unlikely(heading != ['\xFF', '\xFF', '\xFF', '\xFF', 'W', 'A', 'V', 'E', 'd', 's', '6', '4']):
      raise newException(IOError, &"Invalid heading for rf64 chunk: {repr(heading)}")

    var
      chunk_size = stream.readUint32()
      bw_size_low = stream.readUint32()
      bw_size_high = stream.readUint32()
      data_size_low = stream.readUint32()
      data_size_high = stream.readUint32()
      ignore: seq[byte]
      fmt_chunk_received = false
      data_chunk_received = false
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
      n_samples: int

    let
      file_size = mergeUInt32sLE(bw_size_low, bw_size_high)
      data_size = mergeUInt32sLE(data_size_low, data_size_high)

    discard stream.readData(ignore.addr, int(40 - chunk_size))

    while uint64(stream.getPosition()) < file_size:
      discard stream.readData(chunk_id.addr, 4)
      echo chunk_id
      if len(chunk_id) == 0:
        if data_chunk_received:
          break  # EOF but data successfully read
        raise newException(IOError, "Unexpected end of file.")
      elif len(chunk_id) < 4 and not (fmt_chunk_received and data_chunk_received):
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
          discard stream.readData(ignore.addr, int(fmt_size - 16))

      elif chunk_id == ['d', 'a', 't', 'a']:
        data_chunk_received = true
        if unlikely(not fmt_chunk_received):
          raise newException(IOError, "No fmt chunk before data")

        fake_size = stream.readUint32()
        bytes_per_sample = block_align div channels
        n_samples = int(data_size div bytes_per_sample)

        if bytes_per_sample != 2:
          raise newException(IOError, "only support uint16")

        if format_tag != 0x0001:
          raise newException(IOError, "only supports PCM audio")

        let tell: int = int(stream.getPosition())
        var mm = memfiles.open("out.wav", mode=fmRead, mappedSize=n_samples)
        stream.setPosition(tell + int(data_size))

        echo mm
        echo "size", mm.size

        for slice in mm.memSlices:
          echo slice.toOpenArray(char)
        mm.close()
      else:
        # Skip unknown chunk
        fake_size = stream.readUint32()
        if int(fake_size) == 0:
          raise newException(IOError, "Unknown chunk")
        discard stream.readData(ignore.addr, int(fake_size))
  else:
    raise newException(IOError, &"File format {repr(file_sig)} not supported.")



let my_args = os.commandLineParams()

if len(my_args) == 0:
  echo """Auto-Editor is an automatic video/audio creator and editor. By default, it will detect silence and create a new video with those sections cut out. By changing some of the options, you can export to a traditional editor like Premiere Pro and adjust the edits there, adjust the pacing of the cuts, and change the method of editing like using audio loudness and video motion to judge making cuts.

Run:
    auto-editor --help

To get the list of options."""
else:
  let my_input = my_args[0]
  # echo "Extracting Audio"
  # let dir = createTempDir("tmp", "")
  # removeDir(dir)
  let outp = execProcess("ffmpeg",
    args=["-hide_banner", "-y", "-i", my_input, "-map", "0:a:0", "-ac", "2", "-rf64", "always", "out.wav"],
    options={poUsePath, poStdErrToStdOut}
  )

  read("out.wav")
  echo "done"

