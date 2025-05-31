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


type Video* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

func `%`*(self: Video): JsonNode =
  let srcStr = if self.src != nil: self.src[] else: ""
  return %* {
    "name": "video",
    "src": srcStr,
    "start": self.start,
    "dur": self.dur,
    "offset": self.offset,
    "speed": self.speed,
    "stream": self.stream,
  }

type Audio* = object
  src*: ptr string
  start*: int64
  dur*: int64
  offset*: int64
  speed*: float64
  stream*: int64

func `%`*(self: Audio): JsonNode =
  let srcStr = if self.src != nil: self.src[] else: ""
  return %* {
    "name": "audio",
    "src": srcStr,
    "start": self.start,
    "dur": self.dur,
    "offset": self.offset,
    "speed": self.speed,
    "volume": 1,
    "stream": self.stream,
  }

type v3* = object
  tb*: AVRational
  background*: string
  sr*: int64
  layout*: string
  res*: (int64, int64)
  v*: seq[seq[Video]]
  a*: seq[seq[Audio]]


func `%`*(self: v3): JsonNode =
  return %* {
    "version": "3",
    "timebase": $self.tb.num & "/" & $self.tb.den,
    "background": self.background,
    "resolution": [self.res[0], self.res[1]],
    "samplerate": self.sr,
    "layout": self.layout,
    "v": self.v,
    "a": self.a,
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
  var vlayer: seq[Video] = @[]
  var alayer: seq[Audio] = @[]
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
        vlayer.add(Video(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2], stream: 0))
        alayer.add(Audio(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2], stream: 0))
      start += dur
      i += 1

  return v3(v: @[vlayer], a: @[alayer])

