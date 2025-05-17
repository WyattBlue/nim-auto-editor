import std/os
import levels
import info


proc main() =
  if paramCount() < 1:
    echo """Auto-Editor is an automatic video/audio creator and editor. By default, it
will detect silence and create a new video with those sections cut out. By
changing some of the options, you can export to a traditional editor like
Premiere Pro and adjust the edits there, adjust the pacing of the cuts, and
change the method of editing like using audio loudness and video motion to
judge making cuts.
"""
    quit(0)

  if paramStr(1) == "levels":
    levels.main(paramStr(2))
    quit(0)
  elif paramStr(1) == "info":
    info.main(commandLineParams()[1..^1])
    quit(0)
  else:
    stderr.writeLine("unknown subcommand")
    quit(1)



when isMainModule:
  main()