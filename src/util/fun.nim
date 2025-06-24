import std/[strutils, strformat]

from std/math import round, trunc

import ../log

proc splitNumStr*(val: string): (float64, string) =
  var index = 0
  for char in val:
    if char notin "0123456789_ .-":
      break
    index += 1
  let (num, unit) = (val[0 ..< index], val[index .. ^1])
  var floatNum: float64
  try:
    floatNum = parseFloat(num)
  except:
    error fmt"Invalid number: '{val}'"
  return (floatNum, unit)

proc parseBitrate*(input: string): int =
  let (val, unit) = split_num_str(input)

  if unit.toLowerAscii() == "k":
    return int(val * 1000)
  if unit == "M":
    return int(val * 1_000_000)
  if unit == "G":
    return int(val * 1_000_000_000)
  if unit == "":
    return int(val)

  error &"Unknown bitrate: {input}"

proc parseTime*(val: string, tb: float64): int64 =
  let (num, unit) = splitNumStr(val)
  if unit in ["s", "sec", "secs", "second", "seconds"]:
    return round(num * tb).int64
  if unit in ["min", "mins", "minute", "minutes"]:
    return round(num * tb * 60).int64
  if unit == "hour":
    return round(num * tb * 3600).int64
  if unit != "":
    error &"'{val}': Time format got unknown unit: `{unit}`"

  if num != trunc(num):
    error &"'{val}': Time format expects an integer"
  return num.int64


proc mutMargin*(arr: var seq[bool], startM: int, endM: int) =
  # Find start and end indexes
  var startIndex: seq[int] = @[]
  var endIndex: seq[int] = @[]
  let arrlen = len(arr)
  for j in 1 ..< arrlen:
    if arr[j] != arr[j - 1]:
      if arr[j]:
        startIndex.add j
      else:
        endIndex.add j

  # Apply margin
  if startM > 0:
    for i in startIndex:
      for k in max(i - startM, 0) ..< i:
        arr[k] = true

  if startM < 0:
    for i in startIndex:
      for k in i ..< min(i - startM, arrlen):
        arr[k] = false

  if endM > 0:
    for i in endIndex:
      for k in i ..< min(i + endM, arrlen):
        arr[k] = true

  if endM < 0:
    for i in endIndex:
      for k in max(i + endM, 0) ..< i:
        arr[k] = false
