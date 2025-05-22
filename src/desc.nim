import av
import media


proc main*(args: seq[string]) =
  if args.len < 1:
    echo "Display a media's description metadata"
    quit(0)

  let inputFile = args[0]

  for inputFile in args:

    var container = av.open(inputFile)
    let mediaInfo = initMediaInfo(container.formatContext, inputFile)
    container.close()

    if mediaInfo.description == "":
      stdout.write("\nNo description.\n\n")
    else:
      stdout.write("\n" & mediaInfo.description & "\n\n")
