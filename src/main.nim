import std/os
import std/parseopt
import std/posix_utils
import std/strformat
import std/terminal

import cmds/[desc, info, levels, subdump]
import edit
import log


const version* = "0.4.0-pre"

proc main() =
  if paramCount() < 1:
    if stdin.isatty():
      echo """Auto-Editor is an automatic video/audio creator and editor. By default, it
will detect silence and create a new video with those sections cut out. By
changing some of the options, you can export to a traditional editor like
Premiere Pro and adjust the edits there, adjust the pacing of the cuts, and
change the method of editing like using audio loudness and video motion to
judge making cuts.
"""
      quit(0)
  elif paramStr(1) == "info":
    info.main(commandLineParams()[1..^1])
    quit(0)
  elif paramStr(1) == "desc":
    desc.main(commandLineParams()[1..^1])
    quit(0)
  elif paramStr(1) == "levels":
    levels.main(commandLineParams()[1..^1])
    quit(0)
  elif paramStr(1) == "subdump":
    subdump.main(commandLineParams()[1..^1])
    quit(0)

  var args = mainArgs()
  var expecting: string = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      case expecting
      of "":
        args.input = key
      of "output":
        args.output = key
      of "export":
        args.`export` = key
      of "progress":
        args.progress = key
      expecting = ""

    of cmdLongOption:
      if key == "version":
        args.version = true
      elif key == "debug":
        args.debug = true
      elif key in ["export", "output", "progress"]:
        expecting = key
      else:
        error(fmt"Unknown option: {key}")
    of cmdShortOption:
      if key == "V":
        args.version = true
      elif key == "o":
        expecting = "output"
      elif key in ["d", "n"]:
        discard
      else:
        error(fmt"Unknown option: {key}")
    of cmdEnd:
      discard

  if expecting != "":
    error(fmt"--{expecting} needs argument.")

  if args.version:
    echo version
    quit(0)

  if args.debug:
    when defined(windows):
      var cpuArchitecture: string
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
      echo "OS: Windows ", cpuArchitecture
    else:
      let plat = uname()
      echo "OS: ", plat.sysname, " ", plat.release, " ", plat.machine
    echo "Auto-Editor: ", version
    quit(0)

  editMedia(args)

when isMainModule:
  main()
