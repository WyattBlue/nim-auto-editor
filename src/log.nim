import std/tables
import std/terminal
import std/[strutils, strformat]
import std/math


type BarType* = enum
  modern, classic, ascii, machine, none

type mainArgs* = object
  input*: string = ""

  # Editing Options
  margin*: (string, string) = ("0.2s", "0.2s")
  edit*: string = "audio"
  `export`*: string = "default"
  output*: string = ""

  # Display Options
  progress*: BarType = modern
  debug*: bool = false
  quiet*: bool = false
  preview*: bool = false

  # Audio Rendering
  audioCodec*: string = "auto"

  # Misc.
  version*: bool = false
  noOpen*: bool = false


proc conwrite*(msg: string) =
  let columns = terminalWidth()
  let buffer: string = " ".repeat(columns - msg.len - 3)
  stdout.write("  " & msg & buffer & "\r")
  stdout.flushFile()

proc error*(msg: string) {.noreturn.} =
  when defined(debug):
    raise newException(ValueError, msg)

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

type Code* = enum
  webvtt, srt, mov_text, standard, ass, rass

func toTimecode*(secs: float, fmt: Code): string =
  var sign = ""
  var seconds = secs
  if seconds < 0:
    sign = "-"
    seconds = -seconds

  let total_seconds = seconds
  let m_float = total_seconds / 60.0
  let h_float = m_float / 60.0

  let h = int(h_float)
  let m = int(m_float) mod 60
  let s = total_seconds mod 60.0

  case fmt:
  of webvtt:
    if h == 0:
      return fmt"{sign}{m:02d}:{s:06.3f}"
    return fmt"{sign}{h:02d}:{m:02d}:{s:06.3f}"
  of srt, mov_text:
    let s_str = fmt"{s:06.3f}".replace(".", ",")
    return fmt"{sign}{h:02d}:{m:02d}:{s_str}"
  of standard:
    return fmt"{sign}{h:02d}:{m:02d}:{s:06.3f}"
  of ass:
    return fmt"{sign}{h:d}:{m:02d}:{s:05.2f}"
  of rass:
    return fmt"{sign}{h:d}:{m:02d}:{s:02.0f}"
