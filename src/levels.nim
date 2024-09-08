import ffmpeg
import av

proc main(inputFile: string) =
  var container = av.open(inputFile)
  defer: container.close()

  echo "fin"


export main
