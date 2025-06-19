import std/[os, osproc]
import std/terminal
import std/[strutils, strformat]
import std/sequtils
from std/math import round

import av
import log
import media
import ffmpeg
import timeline
import util/[bar, fun]
import cmds/levels
import analyze/[audio, motion, subtitle]

import imports/json
import exports/[fcp7, fcp11, json, shotcut]
import preview
import render/format

proc parseExportString*(exportStr: string): (string, string, string) =
  var kind = exportStr
  var name = "Auto-Editor Media Group"
  var version = "11"

  let colonPos = exportStr.find(':')
  if colonPos == -1:
    return (kind, name, version)

  kind = exportStr[0..colonPos-1]
  let paramsStr = exportStr[colonPos+1..^1]

  var i = 0
  while i < paramsStr.len:
    while i < paramsStr.len and paramsStr[i] == ' ':
      inc i

    if i >= paramsStr.len:
      break

    var paramStart = i
    while i < paramsStr.len and paramsStr[i] != '=':
      inc i

    if i >= paramsStr.len:
      break

    let paramName = paramsStr[paramStart..i-1]
    inc i

    var value = ""
    if i < paramsStr.len and paramsStr[i] == '"':
      inc i
      while i < paramsStr.len:
        if paramsStr[i] == '\\' and i + 1 < paramsStr.len:
          # Handle escape sequences
          inc i
          case paramsStr[i]:
            of '"': value.add('"')
            of '\\': value.add('\\')
            else:
              value.add('\\')
              value.add(paramsStr[i])
        elif paramsStr[i] == '"':
          inc i
          break
        else:
          value.add(paramsStr[i])
        inc i
    else:
      # Unquoted value (until comma or end)
      while i < paramsStr.len and paramsStr[i] != ',':
        value.add(paramsStr[i])
        inc i

    case paramName:
      of "name": name = value
      of "version": version = value
      else: error &"Unknown paramter: {paramName}"

    # Skip comma
    if i < paramsStr.len and paramsStr[i] == ',':
      inc i

  return (kind, name, version)


proc chunkify(arr: seq[bool]): seq[(int64, int64, float64)] =
  var start: int64 = 0
  var j: int64 = 1
  while j < arr.len:
    if arr[j] != arr[j - 1]:
      let speed = (if arr[j-1] == true: 1.0 else: 99999.0)
      result.add (start, j, speed)
      start = j
    inc j
  result.add (start, arr.len.int64, (if arr[j-1] == true: 1.0 else: 99999.0))


proc setOutput(userOut, userExport, path: string): (string, string) =
  var dir, name, ext: string
  if userOut == "" or userOut == "-":
    if path == "":
      error "`--output` must be set."  # When a timeline file is the input.
    (dir, name, ext) = splitFile(path)
  else:
    (dir, name, ext) = splitFile(userOut)

  let root = dir / name

  if ext == "":
    # Use `mp4` as the default, because it is most compatible.
    ext = (if path == "": ".mp4" else: splitFile(path).ext)

  var outExport = userExport

  if userExport == "":
    case ext:
      of ".xml": outExport = "premiere"
      of ".fcpxml": outExport = "final-cut-pro"
      of ".mlt": outExport = "shotcut"
      of ".json", ".v1": outExport = "v1"
      of ".v3": outExport = "v3"
      else: outExport = "default"

  case userExport:
    of "premiere", "resolve-fcp7": ext = ".xml"
    of "final-cut-pro", "resolve": ext = ".fcpxml"
    of "shotcut": ext = ".mlt"
    of "v1": ext = ".v1"
    of "v3": ext = ".v3"
    else: discard

  if userOut == "-":
      return ("-", outExport)

  if userOut == "":
      return (&"{root}_ALTERED{ext}", outExport)

  return (&"{root}{ext}", outExport)

proc editMedia*(args: mainArgs) =
  av_log_set_level(AV_LOG_QUIET)

  var tlV3: v3
  var interner = newStringInterner()
  var output: string
  defer: interner.cleanup()

  if args.progress == BarType.machine and args.output != "-":
    conwrite("Starting")

  if args.input == "" and not stdin.isatty():
    let stdinContent = readAll(stdin)
    tlV3 = readJson(stdinContent, interner)
  else:
    if args.input == "":
      error "You need to give auto-editor an input file."
    let inputExt = splitFile(args.input).ext

    if inputExt in [".v1", ".v3", ".json"]:
      tlV3 = readJson(readFile(args.input), interner)
    else:
      # Make `timeline` from media file
      var container = av.open(args.input)
      defer: container.close()
      var tb = AVRational(30)
      if container.video.len > 0:
        tb = makeSaneTimebase(container.video[0].avgRate)

      var chunks: seq[(int64, int64, float64)] = @[]
      let src = initMediaInfo(container.formatContext, args.input)

      let (editMethod, threshold, stream, width, blur, pattern) = parseEditString(args.edit)

      if editMethod in ["audio", "motion"]:
        let bar = initBar(args.progress)
        let levels = (if editMethod == "audio":
          audio(bar, container, args.input, tb, stream)
          else:
          motion(bar, container, args.input, tb, stream, width, blur)
        )
        var hasLoud = newSeq[bool](levels.len)
        hasLoud = levels.mapIt(it >= threshold)

        let startMargin = parseTime(args.margin[0], tb.float64)
        let endMargin = parseTime(args.margin[1], tb.float64)
        mutMargin(hasLoud, startMargin, endMargin)
        chunks = chunkify(hasLoud)
      elif editMethod == "subtitle":
        var hasLoud = subtitle(container, tb, pattern, stream)
        let startMargin = parseTime(args.margin[0], tb.float64)
        let endMargin = parseTime(args.margin[1], tb.float64)
        mutMargin(hasLoud, startMargin, endMargin)
        chunks = chunkify(hasLoud)
      elif editMethod == "none":
        let length = mediaLength(container)
        let tbLength = (round((length * tb).float64)).int64

        if tbLength > 0:
          chunks.add((0'i64, tbLength, 1.0))
      else:
        error &"Unknown edit method: {editMethod}"

      tlV3 = toNonLinear(addr args.input, tb, src, chunks)

  var exportKind, tlName, fcpVersion: string
  if args.`export` == "":
    (output, exportKind) = setOutput(args.output, "", args.input)
    tlName = "Auto-Editor Media Group"
    fcpVersion = "11"
  else:
    (exportKind, tlName, fcpVersion) = parseExportString(args.`export`)
    (output, _) = setOutput(args.output, exportKind, args.input)

  if args.preview:
    preview(tlV3)
    return

  case exportKind:
  of "premiere":
    fcp7_write_xml(tlName, output, false, tlV3)
    return
  of "resolve-fcp7":
    fcp7_write_xml(tlName, output, true, tlV3)
    return
  of "final-cut-pro":
    fcp11_write_xml(tlName, fcpVersion, output, false, tlV3)
    return
  of "resolve":
    tlV3.setStreamTo0(interner)
    fcp11_write_xml(tlName, fcpVersion, output, true, tlV3)
    return
  of "v1", "v3":
    exportJsonTl(tlV3, exportKind, output)
    return
  of "shotcut":
    shotcut_write_mlt(output, tlV3)
    return
  of "default":
    discard
  else:
    error &"Unknown export format: {exportKind}"

  if args.output == "-":
    error "Exporting media files to stdout is not supported."

  makeMedia(tlV3, output)

  if not args.noOpen and exportKind == "default":
    let process = startProcess("open", args=[output], options={poUsePath})
    discard process.waitForExit()
    process.close()