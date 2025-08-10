import std/strformat
import std/sets

import ../ffmpeg
import ../log

proc defaultVideoCodec*(self: ptr AVOutputFormat): string =
  let codecId = self.video_codec
  if codecId != AV_CODEC_ID_NONE:
    let codecName = avcodec_get_name(codecId)
    if codecName != nil:
      return $codecName
  return "none"

proc defaultAudioCodec*(self: ptr AVOutputFormat): string =
  let codecId = self.audio_codec
  if codecId != AV_CODEC_ID_NONE:
    let codecName = avcodec_get_name(codecId)
    if codecName != nil:
      return $codecName
  return "none"

proc defaultSubtitleCodec*(self: ptr AVOutputFormat): string =
  let codecId = self.subtitle_codec
  if codecId != AV_CODEC_ID_NONE:
    let codecName = avcodec_get_name(codecId)
    if codecName != nil:
      return $codecName
  return "none"

func supportedCodecs*(self: ptr AVOutputFormat): seq[AVCodec] =
  var codec: ptr AVCodec
  let opaque: pointer = nil

  while true:
    codec = av_codec_iterate(addr opaque)
    if codec == nil:
      break
    if avformat_query_codec(self, codec.id, FF_COMPLIANCE_NORMAL) == 1:
      result.add codec[]

type Rules* = object
  allowImage*: bool
  vcodecs*: HashSet[string]
  acodecs*: HashSet[string]
  scodecs*: HashSet[string]
  defaultVid*: string
  defaultAud*: string
  defaultSub*: string
  maxVideos*: int = -1
  maxAudios*: int = -1
  maxSubtitles*: int = -1

proc initRules*(ext: string): Rules =
  let format = av_guess_format(nil, cstring(ext), nil)
  if format == nil:
    error &"Extension: {ext} has no known formats"

  result.defaultVid = format.defaultVideoCodec()
  result.defaultAud = format.defaultAudioCodec()
  result.defaultSub = format.defaultSubtitleCodec()
  result.allowImage = ext in ["mp4", "mkv"]

  for codec in format.supportedCodecs:
    if codec.`type` == AVMEDIA_TYPE_VIDEO:
      result.vcodecs.incl $codec.name
    elif codec.`type` == AVMEDIA_TYPE_AUDIO:
      result.acodecs.incl $codec.name
    elif codec.`type` == AVMEDIA_TYPE_SUBTITLE:
      result.scodecs.incl $codec.name
