import std/json
import std/sequtils
import std/sets
from std/math import round

import ffmpeg

type v1* = object
  chunks*: seq[(int64, int64, float64)]
  source*: string

func `%`*(obj: v1): JsonNode =
  var jsonChunks = obj.chunks.mapIt(%[%it[0], %it[1], %it[2]])
  return %* {"version": "1", "source": obj.source, "chunks": jsonChunks}


type Clip* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

type v3* = object
  tb*: AVRational
  background*: string
  sr*: int64
  layout*: string
  res*: (int64, int64)
  v*: seq[seq[Clip]]
  a*: seq[seq[Clip]]


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


func len*(self: v3): int64 =
  result = 0
  for clips in self.v:
    if len(clips) > 0:
      result = max(result, clips[^1].start + clips[^1].dur)
  for clips in self.a:
    if len(clips) > 0:
      result = max(result, clips[^1].start + clips[^1].dur)

func uniqueSources*(self: v3): HashSet[ptr string] =
  for vlayer in self.v:
    for video in vlayer:
      result.incl(video.src)

  for alayer in self.a:
    for audio in alayer:
      result.incl(audio.src)

func toNonLinear*(src: ptr string, chunks: seq[(int64, int64, float64)]): v3 =
  var vlayer: seq[Clip] = @[]
  var alayer: seq[Clip] = @[]
  var i: int64 = 0
  var start: int64 = 0
  var dur: int64
  var offset: int64

  for chunk in chunks:
    if chunk[2] > 0 and chunk[2] < 99999.0:
      dur = int64(round(float64(chunk[1] - chunk[0]) / chunk[2]))
      if dur == 0:
        continue

      offset = int64(float64(chunk[0]) / chunk[2])

      if not (vlayer.len > 0 and vlayer[^1].start == start):
        vlayer.add(Clip(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2], stream: 0))
        alayer.add(Clip(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2], stream: 0))
      start += dur
      i += 1

  return v3(v: @[vlayer], a: @[alayer])

