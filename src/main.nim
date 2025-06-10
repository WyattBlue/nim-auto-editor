import std/os
import std/posix_utils
import std/strformat
import std/strutils
import std/terminal

import cmds/[info, desc, cache, levels, subdump]
import edit
import log
import about


proc ctrlc() {.noconv.} =
  error "Keyboard Interrupt"

setControlCHook(ctrlc)

proc parseMargin(val: string): (string, string) =
  var vals = val.strip().split(",")
  if vals.len == 1:
    vals.add vals[0]
  if vals.len != 2:
    error "--margin has too many arguments."
  return (vals[0], vals[1])

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
  elif paramStr(1) == "cache":
    cache.main(commandLineParams()[1..^1])
    quit(0)
  elif paramStr(1) == "levels":
    levels.main(commandLineParams()[1..^1])
    quit(0)
  elif paramStr(1) == "subdump":
    subdump.main(commandLineParams()[1..^1])
    quit(0)

  var args = mainArgs()
  var expecting: string = ""

  for key in commandLineParams():
    case key:
    of "-V", "--version":
      args.version = true
    of "-q", "--quiet":
      args.quiet = true
    of "--debug":
      args.debug = true
    of "-dn", "-sn":
      discard
    of "-ex":
      expecting = "export"
    of "-o":
      expecting = "output"
    of "-m":
      expecting = "margin"
    of "--edit", "--export", "--output", "--progress", "--margin":
      expecting = key[2..^1]
    else:
      if key.startsWith("--"):
        error(fmt"Unknown option: {key}")

      case expecting
      of "":
        args.input = key
      of "edit":
        args.edit = key
      of "export":
        args.`export` = key
      of "output":
        args.output = key
      of "progress":
        try:
          args.progress = parseEnum[BarType](key)
        except ValueError:
          error &"{key} is not a choice for --progress\nchoices are:\n  modern, classic, ascii, machine, none"
      of "margin":
        args.margin = parseMargin(key)
      expecting = ""

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
