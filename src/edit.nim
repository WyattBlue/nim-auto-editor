import std/json

import log
import av

proc mediaLength*(inputFile: string): float64 =
  container = av.open(inputFile)

  # Return the length of the first audio stream in seconds
  # by iterating through the packets.

proc editMedia*(args: mainArgs) =

  mediaLength(args.input)


  var tl: JsonNode
  if args.`export` == "v1":
    tl = %* {"version": "1", "source": args.input}
  else:
    tl = %* {"version": "3", "background": "#000000"}

  if args.output == "-":
    echo pretty(tl)
  else:
    writeFile(args.output, pretty(tl))