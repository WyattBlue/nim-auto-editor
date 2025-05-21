import std/os
import std/parseopt
import std/strformat

import levels
import info


type mainArgs = object
  input: string
  help: bool = false
  version: bool = false
  debug: bool = false

proc error(msg: string) =
  stderr.write(fmt"\033[31;40mError! {msg}\033[0m\n")
  quit(1)


const version* = "0.1.0"
var osName: string
var cpuArchitecture: string

when defined(windows):
  osName = "Windows"
elif defined(linux):
  osName = "Linux"
elif defined(macosx):
  osName = "Darwin"
else:
  osName = "Unknown"

when defined(amd64):
  cpuArchitecture = "amd64"
elif defined(i386):
  cpuArchitecture = "i386"
elif defined(arm64):
  cpuArchitecture = "arm64"
elif defined(arm):
  cpuArchitecture = "arm"
else:
  cpuArchitecture = "unknown"


proc main() =
  if paramCount() < 1:
    echo """Auto-Editor is an automatic video/audio creator and editor. By default, it
will detect silence and create a new video with those sections cut out. By
changing some of the options, you can export to a traditional editor like
Premiere Pro and adjust the edits there, adjust the pacing of the cuts, and
change the method of editing like using audio loudness and video motion to
judge making cuts.
"""
    quit(0)

  if paramStr(1) == "levels":
    levels.main(paramStr(2))
    quit(0)
  elif paramStr(1) == "info":
    info.main(commandLineParams()[1..^1])
    quit(0)

  var args = mainArgs()
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      args.input = key
    of cmdLongOption, cmdShortOption:
      if key == "help":
        args.help = true
      elif key == "version":
        args.version = true
      elif key == "debug":
        args.debug = true
      else:
        error(fmt"Unknown option: {key}")
    of cmdEnd:
      discard

  if args.version:
    echo version
    quit(0)

  if args.debug:
    echo "OS: ", osName, " ", cpuArchitecture
    echo "Auto-Editor: ", version
    quit(0)

when isMainModule:
  main()
