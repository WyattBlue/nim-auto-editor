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
