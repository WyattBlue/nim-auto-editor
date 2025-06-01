import std/json
import std/os
import std/options
import std/sequtils

import ../timeline
import ../log

func `%`*(self: v1): JsonNode =
  var jsonChunks = self.chunks.mapIt(%[%it[0], %it[1], %it[2]])
  return %* {"version": "1", "source": self.source, "chunks": jsonChunks}

func `%`*(self: v3): JsonNode =
  var videoTracks = newJArray()
  for track in self.v:
    var trackArray = newJArray()
    for clip in track:
      var clipObj = newJObject()
      clipObj["name"] = %"video"
      clipObj["src"] = %(if clip.src != nil: clip.src[] else: "")
      clipObj["start"] = %clip.start
      clipObj["dur"] = %clip.dur
      clipObj["offset"] = %clip.offset
      clipObj["speed"] = %clip.speed
      clipObj["stream"] = %clip.stream
      trackArray.add(clipObj)
    videoTracks.add(trackArray)

  var audioTracks = newJArray()
  for track in self.a:
    var trackArray = newJArray()
    for clip in track:
      var clipObj = newJObject()
      clipObj["name"] = %"audio"
      clipObj["src"] = %(if clip.src != nil: clip.src[] else: "")
      clipObj["start"] = %clip.start
      clipObj["dur"] = %clip.dur
      clipObj["offset"] = %clip.offset
      clipObj["speed"] = %clip.speed
      clipObj["volume"] = %1
      clipObj["stream"] = %clip.stream
      trackArray.add(clipObj)
    audioTracks.add(trackArray)

  return %* {
    "version": "3",
    "timebase": $self.tb.num & "/" & $self.tb.den,
    "background": self.background,
    "resolution": [self.res[0], self.res[1]],
    "samplerate": self.sr,
    "layout": self.layout,
    "v": videoTracks,
    "a": audioTracks,
  }

proc exportJsonTl*(tlV3: v3, `export`: string, input: string, output: string) =
  var tlJson: JsonNode

  if `export` == "v1":
    if tlV3.chunks.isNone:
      error("No chunks available for export")
    tlJson = %v1(chunks: tlV3.chunks.get, source: input.expandFilename)
  else:
    tlJson = %tlV3

  if tlJson == nil:
    error("tl json object is nil")

  if output == "-":
    echo pretty(tlJson)
  else:
    writeFile(output, pretty(tlJson))
