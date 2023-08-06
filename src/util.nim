import std/strformat
import std/os

type
  Log* = object
    tempDir*: string = ""

func initLog(dir: string = ""): Log =
  return Log(tempDir: dir)

proc error(self: Log, msg: string) =
  stderr.writeLine(&"Error! {msg}")
  if self.tempDir != "":
    removeDir(self.tempDir)
  system.quit(1)

proc endProgram(self: Log) =
  if self.tempDir != "":
    removeDir(self.tempDir)
  system.quit(0)

export Log, error, endProgram, initLog
