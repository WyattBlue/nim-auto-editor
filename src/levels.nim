import ffmpeg

proc main(inputFile: string) =
  var formatContext: ptr AVFormatContext

  if avformat_open_input(addr formatContext, inputFile.cstring, nil, nil) != 0:
    echo "Could not open input file: ", inputFile
    quit(1)

  if avformat_find_stream_info(formatContext, nil) < 0:
    echo "Could not find stream information"
    avformat_close_input(addr formatContext)
    quit(1)

  echo "done"



export main
