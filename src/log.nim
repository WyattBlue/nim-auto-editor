import std/tables
import std/terminal
from std/math import gcd

type mainArgs* = object
  input*: string
  version*: bool = false
  debug*: bool = false
  progress*: string
  output*: string = "-"
  `export`*: string = "v3"


proc error*(msg: string) =
  stderr.styledWriteLine(fgRed, bgBlack, "Error! ", msg, resetStyle)
  quit(1)


type StringInterner* = object
  strings*: Table[string, ptr string]

proc newStringInterner*(): StringInterner =
  result.strings = initTable[string, ptr string]()

proc intern*(interner: var StringInterner, s: string): ptr string =
  if s in interner.strings:
    return interner.strings[s]

  let internedStr = cast[ptr string](alloc0(sizeof(string)))
  internedStr[] = s
  interner.strings[s] = internedStr
  return internedStr

proc cleanup*(interner: var StringInterner) =
  for ptrStr in interner.strings.values:
    dealloc(ptrStr)
  interner.strings.clear()

func aspectRatio*(width, height: int): tuple[w, h: int] =
  if height == 0:
    return (0, 0)
  let c = gcd(width, height)
  return (width div c, height div c)
