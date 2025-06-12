import std/sets
import std/[strutils, strformat]
from std/math import round

import av
import ffmpeg
import timeline
import log

proc timeFrame(title: string, ticks: float, tb: float, per: string = ""): string =
  let tc = toTimecode(ticks / tb, Code.ass)
  let tp = (if tc.startsWith("-"): 9 else: 10)
  let tcp = (if tc.startsWith("-"): 12 else: 11)
  let preci = (if ticks == float(int(ticks)): 0 else: 2)
  let endStr = (if per == "": "" else: " " & alignLeft(per, 7))

  let titlePart = alignLeft(title & ":", tp)
  let tcPart = alignLeft(tc, tcp)
  let ticksPart = (
    if preci == 0: alignLeft(fmt"({ticks.int64})", 6)
    else: alignLeft(fmt"({ticks:.2f})", 6)
  )

  return fmt" - {titlePart} {tcPart} {ticksPart}{endStr}"


proc preview*(tl: v3) =
  conwrite("")

  var inputLength = 0
  for src in tl.uniqueSources:
    let container = av.open(src[])
    let mediaLength: AVRational = container.mediaLength()
    inputLength += round((mediaLength * tl.tb).float64).int

  let outputLength = tl.len
  let diff = outputLength - inputLength
  let tb = tl.tb.float64

  stdout.write("\nlength:\n")
  echo timeFrame("input", inputLength.float64, tb, "100.0%")

  let outputPercent = fmt"{round((outputLength / inputLength) * 100, 2)}%"
  echo timeFrame("output", outputLength.float64, tb, outputPercent)
  echo timeFrame("diff", diff.float64, tb, fmt"{round((diff / inputLength) * 100, 2)}%")