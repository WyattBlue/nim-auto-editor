import std/tables
import std/terminal
import std/strformat


type mainArgs* = object
  input*: string
  version*: bool = false
  debug*: bool = false
  output*: string = "-"
  `export`*: string = "v3"


proc error*(msg: string) =
  stderr.styledWriteLine(fgRed, bgBlack, fmt"Error! {msg}", resetStyle)
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