import std/tables
import std/terminal
import std/strutils
from std/math import gcd


type BarType* = enum
  modern, classic, ascii, machine, none

type mainArgs* = object
  input*: string = ""
  version*: bool = false
  debug*: bool = false
  quiet*: bool = false
  progress*: BarType = modern
  output*: string = "-"
  `export`*: string = "v3"
  edit*: string = "audio"
  margin*: (string, string) = ("0.2s", "0.2s")

proc conwrite*(msg: string) =
  let columns = terminalWidth()
  let buffer: string = " ".repeat(columns - msg.len - 3)
  stdout.write("  " & msg & buffer & "\r")
  stdout.flushFile()

proc error*(msg: string) =
  conwrite("")
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
