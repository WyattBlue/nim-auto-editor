import std/json
import std/os
import std/tables

from std/math import round

import log
import av
import media
import ffmpeg
import timeline
import formats/fcp11

proc mediaLength*(container: InputContainer): float64 =
  # Get the mediaLength in seconds.

  var format_ctx = container.formatContext
  defer: container.close()

  var audioStreamIndex = -1 # Get the first audio stream
  for i in 0..<format_ctx.nb_streams:
    if format_ctx.streams[i].codecpar.codec_type == ffmpeg.AVMEDIA_TYPE_AUDIO:
      audioStreamIndex = int(i)
      break

  if audioStreamIndex != -1:
    var time_base: AVRational
    var packet = ffmpeg.av_packet_alloc()
    var biggest_pts: int64

    while ffmpeg.av_read_frame(format_ctx, packet) >= 0:
      if packet.stream_index == audioStreamIndex:
        if packet.pts != ffmpeg.AV_NOPTS_VALUE and packet.pts > biggest_pts:
          biggest_pts = packet.pts

      ffmpeg.av_packet_unref(packet)

    if packet != nil:
      ffmpeg.av_packet_free(addr packet)

    time_base = format_ctx.streams[audioStreamIndex].time_base
    return float64(biggest_pts.cdouble * time_base.cdouble)

  error("No audio stream found")


type StringInterner* = object
    strings*: Table[string, ptr string]

proc newStringInterner*(): StringInterner =
  result.strings = initTable[string, ptr string]()

proc intern*(interner: var StringInterner, s: string): ptr string =
  if s in interner.strings:
    return interner.strings[s]

  let internedStr = cast[ptr string](alloc0(sizeof(string)))
  internedStr[] = s
  interner.strings[s] = internedStr
  return internedStr

proc cleanup*(interner: var StringInterner) =
  for ptrStr in interner.strings.values:
    dealloc(ptrStr)
  interner.strings.clear()


proc parseVideo(node: JsonNode, interner: var StringInterner): Video =
  result.src = interner.intern(node["src"].getStr())
  result.start = node["start"].getInt()
  result.dur = node["dur"].getInt()
  result.offset = node["offset"].getInt()
  result.speed = node["speed"].getFloat()
  result.stream = node["stream"].getInt()


proc parseAudio(node: JsonNode, interner: var StringInterner): Audio =
  result.src = interner.intern(node["src"].getStr())
  result.start = node["start"].getInt()
  result.dur = node["dur"].getInt()
  result.offset = node["offset"].getInt()
  result.speed = node["speed"].getFloat()
  result.stream = node["stream"].getInt()


proc parseV3(jsonStr: string, interner: var StringInterner): v3 =
  let jsonNode = parseJson(jsonStr)

  if not jsonNode.hasKey("version") or jsonNode["version"].getStr() != "3":
    error("Unsupported version")

  var tb: AVRational
  try:
    tb = jsonNode["timebase"].getStr()
  except ValueError as e:
    error(e.msg)

  result.tb = jsonNode["timebase"].getStr()

  if not jsonNode.hasKey("samplerate") or not jsonNode.hasKey("background"):
    error("sr/bg bad structure")

  result.sr = jsonNode["samplerate"].getInt()
  result.background = jsonNode["background"].getStr()

  if not jsonNode.hasKey("resolution") or jsonNode["resolution"].kind != JArray:
    error("'resolution' has bad structure")

  result.layout = jsonNode["layout"].getStr()

  let resArray = jsonNode["resolution"]
  if resArray.len >= 2:
    result.res = (resArray[0].getInt(), resArray[1].getInt())
  else:
    result.res = (1920, 1080)

  result.v = @[]
  if jsonNode.hasKey("v") and jsonNode["v"].kind == JArray:
    for trackNode in jsonNode["v"]:
      var track: seq[Video] = @[]
      if trackNode.kind == JArray:
        for videoNode in trackNode:
          track.add(parseVideo(videoNode, interner))
      result.v.add(track)

  # Parse audio tracks
  result.a = @[]
  if jsonNode.hasKey("a") and jsonNode["a"].kind == JArray:
    for trackNode in jsonNode["a"]:
      var track: seq[Audio] = @[]
      if trackNode.kind == JArray:
        for audioNode in trackNode:
          track.add(parseAudio(audioNode, interner))
      result.a.add(track)

proc editMedia*(args: mainArgs) =
  let inputExt = splitFile(args.input).ext

  var tb: AVRational
  var tl: JsonNode
  var tlV3: v3

  var chunks: seq[(int64, int64, float64)]
  var src: MediaInfo
  var interner = newStringInterner()

  if inputExt == ".v3":
    tlV3 = parseV3(readFile(args.input), interner)
    tb = tlV3.tb
  else:
    var container = av.open(args.input)

    tb = AVRational(num: 30, den: 1)

    # Get the timeline resolution from the first video stream.
    src = initMediaInfo(container.formatContext, args.input)
    let length = mediaLength(container)
    let tbLength = int64(round(tb.cdouble * length))

    if tbLength > 0:
      chunks.add((0'i64, tbLength, 1.0))


  if args.`export` == "v1":
    var tlObj = v1(chunks: chunks, source: args.input)
    tl = %tlObj
  elif tlV3.sr == 0:
    tlV3 = toNonLinear(addr args.input, chunks)
    tlV3.tb = tb
    tlV3.background = "#000000"
    tlV3.res = src.get_res()
    tlV3.sr = 48000
    tlV3.layout = "stereo"
    if src.a.len > 0:
      tlV3.sr = src.a[0].sampleRate
      tlV3.layout = src.a[0].layout

    tl = %tlV3

  if args.`export` == "final-cut-pro":
    fcp11_write_xml("Auto-Editor Media Group", 11, args.output, false, tlV3)
  elif args.`export` == "v1" or args.`export` == "v3":
    if args.output == "-":
      echo pretty(tl)
    else:
      writeFile(args.output, pretty(tl))
  else:
    error("Unknown export format")
