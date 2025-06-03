import std/sets
import std/options
import std/os
import std/tables
from std/math import round

import ffmpeg
import media
import log
import wavutil

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

func toNonLinear*(src: ptr string, tb: AvRational, mi: MediaInfo, chunks: seq[(
    int64, int64, float64)]): v3 =
  var clips: seq[Clip] = @[]
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

      if not (clips.len > 0 and clips[^1].start == start):
        clips.add(Clip(src: src, start: start, dur: dur, offset: offset,
            speed: chunk[2]))
      start += dur
      i += 1

  var vspace: seq[seq[Clip]] = @[]
  var aspace: seq[seq[Clip]] = @[]

  if mi.v.len > 0:
    var vlayer: seq[Clip] = @[]
    for clip in clips:
      var videoClip = clip
      videoClip.stream = 0
      vlayer.add(videoClip)
    vspace.add(vlayer)

  for i in 0 ..< mi.a.len:
    var alayer: seq[Clip] = @[]
    for clip in clips:
      var audioClip = clip
      audioClip.stream = i
      alayer.add(audioClip)
    aspace.add(alayer)

  result = v3(v: vspace, a: aspace, chunks: some(chunks))
  result.background = "#000000"
  result.tb = tb
  result.res = mi.get_res()
  result.sr = 48000
  result.layout = "stereo"
  if mi.a.len > 0:
    result.sr = mi.a[0].sampleRate
    result.layout = mi.a[0].layout


proc stem(path: string): string =
  splitFile(path).name


proc setStreamTo0*(tl: var v3, interner: var StringInterner) =
  var dirExists = false
  var cache = initTable[string, MediaInfo]()

  proc makeTrack(i: int64, path: string): MediaInfo =
    let folder: string = path.parentDir / (path.stem & "_tracks")
    if not dirExists:
      try:
        createDir(folder)
      except OSError:
        removeDir(folder)
        createDir(folder)
      dirExists = true

    let newtrack: string = folder / (path.stem & "_" & $i & ".wav")
    if newtrack notin cache:
      toS16Wav(path, newtrack, i)
      cache[newtrack] = initMediaInfo(newtrack)
    return cache[newtrack]

  for layer in tl.a.mitems:
    for clip in layer.mitems:
      if clip.stream > 0:
        let mi = makeTrack(clip.stream, clip.src[])
        clip.src = interner.intern(mi.path)
        clip.stream = 0
