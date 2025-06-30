import std/[os, osproc, posix_utils]
import std/[strformat, strutils]
import std/terminal
import std/uri

import about
import edit
import log
import cmds/[info, desc, cache, levels, subdump]
import util/fun

import tinyre

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
                                  section is less than LENGTH away. (default is
                                  "0.2s")
    --edit METHOD                 Set an expression which determines how to
                                  make auto edits
    -ex, --export EXPORT:ATTRS?   Choose the export mode. (default is
                                  "audio")
    -o, --output FILE             Set the name/path of the new output file
    -s, --silent-speed NUM        Set speed of sections marked "silent" to
                                  NUM. (default is 99999)
    -v, --sounded-speed, --video-speed NUM
                                  Set speed of sections marked "loud" to
                                  NUM. (default is 1)
    --cut-out [START,STOP ...]    The range of media that will be removed
                                  (cut out) completely
    --add-in [START,STOP ...]     The range of media that will be added in,
                                  will apply --video-speed
    --set-speed, --set-speed-for-range [SPEED,START,STOP ...]
                                  Set the SPEED for a given range

  URL Download Options:
    --yt-dlp-location PATH        Set a custom path to yt-dlp
    --download-format FORMAT      Set the yt-dlp download format (--format, -f)
    --output-format TEMPLATE      Set the yt-dlp output file template (
                                  --output, -o)
    --yt-dlp-extras CMD           Add extra options for yt-dlp. Must be in
                                  quotes

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

proc parseMargin(val: string): (PackedInt, PackedInt) =
  var vals = val.strip().split(",")
  if vals.len == 1:
    vals.add vals[0]
  if vals.len != 2:
    error "--margin has too many arguments."
  return (parseTime(vals[0]), parseTime(vals[1]))

proc parseTimeRange(val, opt: string): (PackedInt, PackedInt) =
  var vals = val.strip().split(",")
  if vals.len < 2:
    error &"--{opt} has too few arguments"
  if vals.len > 2:
    error &"--{opt} has too many arguments"
  return (parseTime(vals[0]), parseTime(vals[1]))

proc parseSpeed(val, opt: string): float64 =
  let (num, unit) = splitNumStr(val)
  if unit == "%":
    result = num / 100.0
  elif unit == "":
    result = num
  else:
    error &"--{opt} has unknown unit: {unit}"

  if result <= 0.0 or result > 99999.0:
    result = 99999.0

proc parseSpeedRange(val: string): (float64, PackedInt, PackedInt) =
  var vals = val.strip().split(",")
  if vals.len < 3:
    error &"--set-speed has too few arguments"
  if vals.len > 3:
    error &"--set-speed has too many arguments"
  return (parseSpeed(vals[0], "set-speed"), parseTime(vals[1]), parseTime(vals[2]))

func handleKey(val: string): string =
  if val.startsWith("--") and val.len >= 3:
    return val[0 ..< 3] & val[3 .. ^1].replace("_", "-")
  return val

proc downloadVideo(myInput: string, args: mainArgs): string =
  conwrite("Downloading video...")

  proc getDomain(url: string): string =
    let parsed = parseUri(url)
    var hostname = parsed.hostname
    if hostname.startsWith("www."):
      hostname = hostname[4..^1]
    return hostname

  var downloadFormat = args.downloadFormat
  if downloadFormat == "" and getDomain(myInput) == "youtube.com":
    downloadFormat = "bestvideo[ext=mp4]+bestaudio[ext=m4a]"

  var outputFormat: string
  if args.outputFormat == "":
    outputFormat = replacef(splitext(myInput)[0], re"\W+", "-") & ".%(ext)s"
  else:
    outputFormat = args.outputFormat

  var cmd: seq[string] = @[]
  if downloadFormat != "":
    cmd.add(@["-f", downloadFormat])

  cmd.add(@["-o", outputFormat, myInput])
  if args.yt_dlp_extras != "":
    cmd.add(args.ytDlpExtras.split(" "))

  let ytDlpPath = args.ytDlpLocation
  var location: string
  try:
    location = execProcess(ytDlpPath,
      args = @["--get-filename", "--no-warnings"] & cmd,
      options = {poUsePath}).strip()
  except OSError:
    error "Program `yt-dlp` must be installed and on PATH."

  if not fileExists(location):
    let p = startProcess(ytDlpPath, args = cmd, options = {poUsePath, poParentStreams})
    defer: p.close()
    discard p.waitForExit()

  if not fileExists(location):
    error &"Download file wasn't created: {location}"

  return location

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
  var showVersion: bool = false
  var expecting: string = ""

  for rawKey in commandLineParams():
    let key = handleKey(rawKey)
    case key:
    of "-h", "--help":
      printHelp()
    of "-V", "--version":
      showVersion = true
    of "-q", "--quiet":
      quiet = true
    of "--debug":
      args.debug = true
    of "--preview", "--stats":
      args.preview = true
    of "--no-open":
      args.noOpen = true
    of "-dn", "-sn":
      discard
    of "-ex", "--export":
      expecting = "export"
    of "-exp", "--export-to-premiere":
      args.`export` = "premiere"
    of "-exr", "--export-to-resolve":
      args.`export` = "resolve"
    of "-exf", "--export-to-final-cut-pro":
      args.`export` = "final-cut-pro"
    of "-exs", "--export-to-shotcut":
      args.`export` = "shotcut"
    of "-o", "--output":
      expecting = "output"
    of "-m", "--margin", "--frame-margin":
      expecting = "margin"
    of "-s", "--silent-speed":
      expecting = "silent-speed"
    of "-v", "--video-speed", "--sounded-speed":
      expecting = "video-speed"
    of "-c:a", "-acodec", "--audio-codec":
      expecting = "audio-codec"
    of "--edit", "--edit-based-on":
      expecting = "edit"
    of "--set-speed", "--set-speed-for-range":
      expecting = "set-speed"
    of "--progress", "--add-in", "--cut-out", "--yt-dlp-location", "--download-format", "--output-format", "--yt-dlp-extras":
      expecting = key[2..^1]
    else:
      if key.startsWith("--"):
        error(&"Unknown option: {key}")

      case expecting
      of "":
        args.input = key
      of "edit":
        args.edit = key
      of "export":
        args.`export` = key
      of "output":
        args.output = key
      of "silent-speed":
        args.silentSpeed = parseSpeed(key, expecting)
      of "video-speed":
        args.videoSpeed = parseSpeed(key, expecting)
      of "add-in":
        args.addIn.add parseTimeRange(key, expecting)
      of "cut-out":
        args.cutOut.add parseTimeRange(key, expecting)
      of "set-speed":
        args.setSpeed.add parseSpeedRange(key)
      of "yt-dlp-location":
        args.ytDlpLocation = key
      of "download-format":
        args.downloadFormat = key
      of "output-format":
        args.outputFormat = key
      of "yt-dlp-extras":
        args.ytDlpExtras = key
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
    error(&"--{expecting} needs argument.")

  if showVersion:
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

  let myInput = args.input
  if myInput.startswith("http://") or myInput.startswith("https://"):
    args.input = downloadVideo(myInput, args)
  elif splitFile(myInput).ext == "":
    if dirExists(myInput):
      error(&"Input must be a file or a URL, not a directory.")
    if myInput.startswith("-"):
      error(&"Option/Input file doesn't exist: {myInput}")
    error(&"Input file must have an extension: {myInput}")

  editMedia(args)

when isMainModule:
  main()
