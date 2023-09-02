import std/[math, strutils, strformat, terminal]

type Bar = object
  total*: int
  label*: string


proc tick(self: Bar, index: int) =
  if index != 0:
    cursorUp 1
    eraseLine()

  let
    chars = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]
    progress = (if self.total == 0: 0.0 else: min(1, max(0, index / self.total)))
    width = terminalWidth()
    bar_len = max(1, width - (len(self.label) + 32))
    whole_width = toInt(progress * toFloat(bar_len))
    remainder_width = (progress * toFloat(bar_len)) mod 1.0
    part_width = toInt(remainder_width * toFloat(chars.len - 1))
    part_char = (if bar_len - whole_width - 1 < 0: "" else: chars[part_width])
    inner_bar = repeat(chars[^1], whole_width) & part_char & repeat(chars[0], bar_len - whole_width - 1)

  var bar = &"  ⏳{self.label} |{inner_bar}|  {index}/{self.total}"

  if not (len(bar) > width - 2):
    bar &= " ".repeat(width - len(bar) - 4)

  stdout.writeLine(bar)

proc initBar(total: int, label: string = "Creating new video"): Bar =
  let bar = Bar(total:total, label:label)
  bar.tick(0)
  return bar

export Bar, initBar, tick