import std/tables
import std/terminal
import std/[strutils, strformat]
import std/math


type BarType* = enum
  modern, classic, ascii, machine, none

type PackedInt* = distinct int64

proc pack*(flag: bool, number: int64): PackedInt =
  let maskedNumber = number and 0x7FFFFFFFFFFFFFFF'i64
  let flagBit = if flag: 0x8000000000000000'i64 else: 0'i64
  PackedInt(flagBit or maskedNumber)

proc getFlag*(packed: PackedInt): bool =
  int64(packed) < 0

proc getNumber*(packed: PackedInt): int64 =
  let raw = int64(packed) and 0x7FFFFFFFFFFFFFFF'i64
  if (raw and 0x4000000000000000'i64) != 0:
    raw or 0x8000000000000000'i64
  else:
    raw

type mainArgs* = object
  input*: string = ""

  # Editing Options
  margin*: (PackedInt, PackedInt) = (pack(true, 200), pack(true, 200)) # 0.2s
  edit*: string = "audio"
  `export`*: string = "default"
  output*: string = ""
  silentSpeed*: float64 = 99999.0
  videoSpeed*: float64 = 1.0
  cutOut*: seq[(PackedInt, PackedInt)]
  addIn*: seq[(PackedInt, PackedInt)]
  setSpeed*: seq[(float64, PackedInt, PackedInt)]

  # Display Options
  progress*: BarType = modern
  debug*: bool = false
  preview*: bool = false

  # Audio Rendering
  audioCodec*: string = "auto"

  # Misc.
  noOpen*: bool = false

var quiet* = false

proc conwrite*(msg: string) =
  if not quiet:
    let columns = terminalWidth()
    let buffer: string = " ".repeat(columns - msg.len - 3)
    stdout.write("  " & msg & buffer & "\r")
    stdout.flushFile()

proc error*(msg: string) {.noreturn.} =
  when defined(windows):
    showCursor()

  when defined(debug):
    raise newException(ValueError, msg)
  else:
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
