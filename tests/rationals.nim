import unittest
import std/os
import std/tempfiles

import ../src/[av, ffmpeg]
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
  check(sizeof(Clip) == 48)

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

test "dialouge":
  check("0,0,Default,,0,0,0,,oop".dialogue == "oop")
  check("0,0,Default,,0,0,0,,boop".dialogue == "boop")

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

test "wav":
  let tempDir = createTempDir("tmp", "")
  let outWav = tempDir / "out.wav"
  toS16Wav("example.mp4", outWav, 0)
  removeDir(tempDir)
