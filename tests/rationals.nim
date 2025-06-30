import unittest
import std/os
import std/tempfiles

import ../src/[av, ffmpeg]
import ../src/util/[fun, color]
import ../src/edit
import ../src/wavutil
import ../src/cmds/info
import ../src/media
import ../src/timeline

test "struct-sizes":
  check(sizeof(AVRational) == 8)
  check(sizeof(seq) == 16)
  check(sizeof(string) == 16)
  check(sizeof(ref string) == 8)
  check(sizeof(ref seq) == 8)
  check(sizeof(VideoStream) == 144)
  check(sizeof(AudioStream) == 72)
  check(sizeof(Clip) == 56)

test "maths":
  let a = AVRational(num: 3, den: 4)
  let b = AVRational(num: 3, den: 4)
  check(a + b == AVRational(num: 3, den: 2))
  check(a + a == a * 2)

  let intThree: int64 = 3
  check(intThree / AVRational(3) == AVRational(1))
  check(intThree * AVRational(3) == AVRational(9))

  check(AVRational(num: 9, den: 3).int64 == intThree)
  check(AVRational(num: 10, den: 3).int64 == intThree)
  check(AVRational(num: 11, den: 3).int64 == intThree)

test "strings":
  check(AVRational("42") == AVRational(42))
  check(AVRational("-2/3") == AVRational(num: -2, den: 3))
  check(AVRational("6/8") == AVRational(num: 3, den: 4))
  check(AVRational("1.5") == AVRational(num: 3, den: 2))

test "color":
  check(RGBColor(red: 0, green: 0, blue: 0).toString == "#000000")
  check(RGBColor(red: 255, green: 255, blue: 255).toString == "#ffffff")

  check(parseColor("#000") == RGBColor(red: 0, green: 0, blue: 0))
  check(parseColor("#000000") == RGBColor(red: 0, green: 0, blue: 0))
  check(parseColor("#FFF") == RGBColor(red: 255, green: 255, blue: 255))
  check(parseColor("#fff") == RGBColor(red: 255, green: 255, blue: 255))
  check(parseColor("#FFFFFF") == RGBColor(red: 255, green: 255, blue: 255))

  check(parseColor("black") == RGBColor(red: 0, green: 0, blue: 0))
  check(parseColor("darkgreen") == RGBColor(red: 0, green: 100, blue: 0))

test "encoder":
  let (_, encoderCtx) = initEncoder("pcm_s16le")
  check(encoderCtx.codec_type == AVMEDIA_TYPE_AUDIO)
  check(encoderCtx.bit_rate != 0)

  let (_, encoderCtx2) = initEncoder(AV_CODEC_ID_PCM_S16LE)
  check(encoderCtx2.codec_type == AVMEDIA_TYPE_AUDIO)
  check(encoderCtx2.bit_rate != 0)

test "exports":
  check(parseExportString("premiere:name=a,version=3") == ("premiere", "a", "3"))
  check(parseExportString("premiere:name=a") == ("premiere", "a", "11"))
  check(parseExportString("premiere:name=\"Hello \\\" World") == ("premiere", "Hello \" World", "11"))
  check(parseExportString("premiere:name=\"Hello \\\\ World") == ("premiere", "Hello \\ World", "11"))

test "info":
  main(@["example.mp4"])

test "margin":
  var levels: seq[bool]
  levels = @[false, false, true, false, false]
  mutMargin(levels, 0, 1)
  check(levels == @[false, false, true, true, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 1, 0)
  check(levels == @[false, true, true, false, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 1, 1)
  check(levels == @[false, true, true, true, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 2, 2)
  check(levels == @[true, true, true, true, true])

test "wav1":
  let tempDir = createTempDir("tmp", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.wav"
  muxAudio("example.mp4", outFile, 0)

  let container = av.open(outFile)
  defer: container.close()
  check(container.audio.len == 1)
  check($container.audio[0].name == "pcm_s16le")

test "mp3":
  let tempDir = createTempDir("tmp", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mp3"
  muxAudio("example.mp4", outFile, 0)

  let container = av.open(outFile)
  defer: container.close()
  check(container.audio.len == 1)
  check($container.audio[0].name in ["mp3", "mp3float"])

test "aac":
  let tempDir = createTempDir("tmp", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.aac"
  muxAudio("example.mp4", outFile, 0)

  let container = av.open(outFile)
  defer: container.close()
  check(container.audio.len == 1)
  check($container.audio[0].name == "aac")

test "dialouge":
  check("0,0,Default,,0,0,0,,oop".dialogue == "oop")
  check("0,0,Default,,0,0,0,,boop".dialogue == "boop")
