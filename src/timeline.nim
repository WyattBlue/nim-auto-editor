import std/sets
import std/options
from std/math import round

import ffmpeg

type v1* = object
  chunks*: seq[(int64, int64, float64)]
  source*: string

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
  chunks*: Option[seq[(int64, int64, float64)]]


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

  return v3(v: @[vlayer], a: @[alayer], chunks: some(chunks),
      background: "#000000")

