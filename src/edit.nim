import std/json

import log

proc edit_media*(args: mainArgs) =
  var tl: JsonNode
  if args.`export` == "v1":
    tl = %* {"version": "1", "source": args.input}
  else:
    tl = %* {"version": "3", "background": "#000000"}

  if args.output == "-":
    echo pretty(tl)
  else:
    writeFile(args.output, pretty(tl))