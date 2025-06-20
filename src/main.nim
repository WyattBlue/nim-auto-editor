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

proc printHelp() {.noreturn.} =
  echo """Usage: [file | url ...] [options]

Commands:
  info desc cache levels subdump

Options:
  Editing Options:
    -m, --margin LENGTH           Set sections near "loud" as "loud" too if
                                  section is less than LENGTH away
    --edit METHOD                 Set an expression which determines how to
                                  make auto edits
    -ex, --export EXPORT:ATTRS?   Choose the export mode
    -o, --output FILE             Set the name/path of the new output file

  Display Options:
    --progress PROGRESS           Set what type of progress bar to use
    --debug                       Show debugging messages and values
    -q, --quiet                   Display less output
    --preview, --stats            Show stats on how the input will be cut
                                  and halt

  Audio Rendering:
    -c:a, -acodec, --audio-codec ENCODER
                                  Set audio codec for output media
  Miscellaneous:
    --no-open                     Do not open the output file after editing
                                  is done
    -V, --version                 Display version and halt
    -h, --help                    Show info about this program or option
                                  then exit
"""
  quit(0)

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
    of "-h", "--help":
      printHelp()
    of "-V", "--version":
      args.version = true
    of "-q", "--quiet":
      args.quiet = true
    of "--debug":
      args.debug = true
    of "--preview", "--stats":
      args.preview = true
    of "--no-open":
      args.noOpen = true
    of "-dn", "-sn":
      discard
    of "-ex":
      expecting = "export"
    of "-o":
      expecting = "output"
    of "-m":
      expecting = "margin"
    of "-c:a", "-acodec", "--audio-codec":
      expecting = "audio-codec"
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
      of "audio-codec":
        args.audioCodec = key
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
