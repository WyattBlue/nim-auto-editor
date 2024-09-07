import os

{.passC: "-I" & getEnv("HOME") & "/ffmpeg_build/include".}
{.passL: "-L" & getEnv("HOME") & "/ffmpeg_build/lib -lavformat -lavcodec -lavutil".}

type
  AVMediaType* = cint
  AVCodecID* = cint
  AVColorRange* = cint
  AVColorPrimaries* = cint
  AVColorTransferCharacteristic* = cint
  AVColorSpace* = cint

  AVPixelFormat* = distinct cint

  AVRational* {.importc, header: "<libavutil/rational.h>", bycopy.} = object
    num*: cint
    den*: cint

  AVDictionary* {.importc, header: "<libavutil/dict.h>".} = object

  AVDictionaryEntry* {.importc, header: "<libavutil/dict.h>".} = object
    key*: cstring
    value*: cstring

  AVChannelLayout* {.importc, header: "<libavutil/channel_layout.h>", bycopy.} = object
    order*: cint
    nb_channels*: cint
    u*: AVChannelLayoutMask
    opaque*: pointer

  AVChannelLayoutMask* {.union.} = object
    mask*: uint64
    map*: array[64, uint8]

  AVFormatContext* {.importc, header: "<libavformat/avformat.h>".} = object
    av_class*: pointer
    iformat*: pointer
    oformat*: pointer
    priv_data*: pointer
    pb*: pointer
    ctx_flags*: cint
    nb_streams*: cuint
    streams*: ptr UncheckedArray[ptr AVStream]
    filename*: array[1024, char]
    url*: cstring
    start_time*: int64
    duration*: int64
    bit_rate*: int64
    packet_size*: cuint
    max_delay*: cint
    flags*: cint
    probesize*: int64
    max_analyze_duration*: int64

    # ... other fields omitted for brevity

  AVStream* {.importc, header: "<libavformat/avformat.h>".} = object
    index*: cint
    id*: cint
    codecpar*: ptr AVCodecParameters
    time_base*: AVRational
    start_time*: int64
    duration*: int64
    nb_frames*: int64
    disposition*: cint
    sample_aspect_ratio*: AVRational
    metadata*: pointer
    avg_frame_rate*: AVRational

  AVCodecParameters* {.importc, header: "<libavcodec/avcodec.h>".} = object
    codec_type*: AVMediaType
    codec_id*: AVCodecID
    codec_tag*: cuint
    extradata*: ptr uint8
    extradata_size*: cint
    format*: cint
    bit_rate*: int64
    bits_per_coded_sample*: cint
    bits_per_raw_sample*: cint
    profile*: cint
    level*: cint
    width*: cint
    height*: cint
    sample_aspect_ratio*: AVRational
    field_order*: cint
    color_range*: AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*: AVColorTransferCharacteristic
    color_space*: AVColorSpace
    chroma_location*: cint
    video_delay*: cint
    ch_layout*: AVChannelLayout
    sample_rate*: cint
    block_align*: cint
    frame_size*: cint
    initial_padding*: cint
    trailing_padding*: cint
    seek_preroll*: cint


  AVCodecContext* {.importc, header: "<libavcodec/avcodec.h>".} = object
    av_class*: pointer
    log_level_offset*: cint
    codec_type*: AVMediaType
    codec*: pointer
    codec_id*: AVCodecID
    codec_tag*: cuint
    priv_data*: pointer
    internal*: pointer
    opaque*: pointer
    bit_rate*: int64
    bit_rate_tolerance*: cint
    global_quality*: cint
    compression_level*: cint
    flags*: cint
    flags2*: cint
    extradata*: ptr uint8
    extradata_size*: cint
    time_base*: AVRational
    ticks_per_frame*: cint
    delay*: cint
    width*, height*: cint
    coded_width*, coded_height*: cint
    ch_layout*: AVChannelLayout
    gop_size*: cint
    pix_fmt*: AVPixelFormat
    # ... other fields omitted for brevity
    sample_rate*: cint
    sample_fmt*: cint  # This is actually AVSampleFormat, which is just an alias for cint
    sample_aspect_ratio*: AVRational

    # ... other fields omitted for brevity
    color_range*: AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*: AVColorTransferCharacteristic
    colorspace*: AVColorSpace
    chroma_sample_location*: cint
    # ... other fields omitted for brevity

const
  AVMEDIA_TYPE_UNKNOWN* = AVMediaType(-1)
  AVMEDIA_TYPE_VIDEO* = AVMediaType(0)
  AVMEDIA_TYPE_AUDIO* = AVMediaType(1)
  AVMEDIA_TYPE_SUBTITLE* = AVMediaType(2)
  AV_TIME_BASE* = 1000000


# Procedure declarations remain the same
proc avformat_open_input*(ps: ptr ptr AVFormatContext, filename: cstring, fmt: pointer, options: pointer): cint {.importc, header: "<libavformat/avformat.h>".}
proc avformat_find_stream_info*(ic: ptr AVFormatContext, options: pointer): cint {.importc, header: "<libavformat/avformat.h>".}
proc avformat_close_input*(s: ptr ptr AVFormatContext) {.importc, header: "<libavformat/avformat.h>".}
proc av_mul_q*(b: AVRational, c: AVRational): AVRational {.importc, header: "<libavutil/rational.h>".}
proc av_q2d*(a: AVRational): cdouble {.importc, header: "<libavutil/rational.h>".}
proc avcodec_parameters_to_context*(codec_ctx: ptr AVCodecContext, par: ptr AVCodecParameters): cint {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_alloc_context3*(codec: pointer): ptr AVCodecContext {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_free_context*(avctx: ptr ptr AVCodecContext) {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_get_name*(id: AVCodecID): cstring {.importc, header: "<libavcodec/avcodec.h>".}
proc av_get_channel_layout_string*(buf: cstring, buf_size: cint, nb_channels: cint, channel_layout: uint64): cstring {.importc, header: "<libavutil/channel_layout.h>".}
proc av_get_pix_fmt_name*(pix_fmt: AVPixelFormat): cstring {.importc, cdecl.}
proc av_dict_get*(m: ptr AVDictionary, key: cstring, prev: ptr AVDictionaryEntry, flags: cint): ptr AVDictionaryEntry {.importc, header: "<libavutil/dict.h>".}
proc av_channel_layout_describe*(ch_layout: ptr AVChannelLayout, buf: cstring, buf_size: csize_t): cint {.importc, header: "<libavutil/channel_layout.h>".}
