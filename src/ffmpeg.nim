{.passC: "-I./ffmpeg_build/include".}
{.passL: "-L./ffmpeg_build/lib -lavformat -lavcodec -lavutil -lswresample".}

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

  AVSampleFormat* {.importc: "enum AVSampleFormat", header: "<libavutil/samplefmt.h>".} = enum
    AV_SAMPLE_FMT_NONE = -1,
    AV_SAMPLE_FMT_U8,
    AV_SAMPLE_FMT_S16,
    AV_SAMPLE_FMT_S32,
    AV_SAMPLE_FMT_FLT,
    AV_SAMPLE_FMT_DBL,

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
    delay*: cint
    width*, height*: cint
    coded_width*, coded_height*: cint
    ch_layout*: AVChannelLayout
    gop_size*: cint
    pix_fmt*: AVPixelFormat
    # ... other fields omitted for brevity
    sample_rate*: cint
    sample_fmt*: AVSampleFormat
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
  AV_NOPTS_VALUE* = -9223372036854775807'i64 - 1

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

type AVCodec* {.importc, header: "<libavcodec/codec.h>", bycopy.} = object
  capabilities*: cint
  `type`*: AVMediaType

type
  AVPacket* {.importc, header: "<libavcodec/packet.h>", bycopy.} = object
    buf*: pointer           # reference counted buffer holding the data
    pts*: int64             # presentation timestamp in time_base units
    dts*: int64             # decompression timestamp in time_base units
    data*: ptr uint8        # data pointer
    size*: cint             # size of data in bytes
    stream_index*: cint     # stream index this packet belongs to
    flags*: cint
    side_data*: pointer     # pointer to array of side data
    side_data_elems*: cint  # number of side data elements
    duration*: int64        # duration of this packet in time_base units, 0 if unknown
    pos*: int64             # byte position in stream, -1 if unknown
    opaque*: pointer        # time when packet is created
    opaque_ref*: pointer    # reference to opaque
    time_base*: AVRational  # time base of the packet

  AVFrame* {.importc: "AVFrame", header: "<libavutil/frame.h>", bycopy.} = object
    data*: array[8, ptr uint8]
    linesize*: array[8, cint]
    extended_data*: ptr ptr uint8
    width*, height*: cint
    nb_samples*: cint
    format*: cint
    key_frame*: cint
    pict_type*: AVPictureType
    sample_aspect_ratio*: AVRational
    pts*: int64
    pkt_dts*: int64
    time_base*: AVRational
    coded_picture_number*: cint
    display_picture_number*: cint
    quality*: cint
    opaque*: pointer
    repeat_pict*: cint
    interlaced_frame*: cint
    top_field_first*: cint
    palette_has_changed*: cint
    reordered_opaque*: int64
    # buf*: array[8, ptr AVBufferRef]
    # extended_buf*: ptr ptr AVBufferRef
    nb_extended_buf*: cint
    # side_data*: ptr ptr AVFrameSideData
    # nb_side_data*: cint
    flags*: cint
    color_range*: AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*: AVColorTransferCharacteristic
    colorspace*: AVColorSpace
    # chroma_location*: AVChromaLocation
    best_effort_timestamp*: int64
    pkt_pos*: int64
    pkt_duration*: int64
    metadata*: ptr AVDictionary
    decode_error_flags*: cint
    pkt_size*: cint
    # hw_frames_ctx*: ptr AVBufferRef
    # opaque_ref*: ptr AVBufferRef
    crop_top*: csize_t
    crop_bottom*: csize_t
    crop_left*: csize_t
    crop_right*: csize_t
    # private_ref*: ptr AVBufferRef

  AVPictureType* {.importc: "enum AVPictureType", header: "<libavutil/avutil.h>".} = enum
    AV_PICTURE_TYPE_NONE = 0,
    AV_PICTURE_TYPE_I,
    AV_PICTURE_TYPE_P,
    AV_PICTURE_TYPE_B,
    AV_PICTURE_TYPE_S,
    AV_PICTURE_TYPE_SI,
    AV_PICTURE_TYPE_SP,
    AV_PICTURE_TYPE_BI

  # AVBufferRef* {.importc: "AVBufferRef", header: "<libavutil/buffer.h>", bycopy.} = object
  #   buffer*: ptr AVBuffer
  #   data*: ptr uint8
  #   size*: cint

  AVFrameSideData* {.importc: "AVFrameSideData", header: "<libavutil/frame.h>", bycopy.} = object
    `type`*: AVFrameSideDataType
    data*: ptr uint8
    size*: cint
    metadata*: ptr AVDictionary

  AVFrameSideDataType* {.importc: "enum AVFrameSideDataType", header: "<libavutil/frame.h>".} = enum
    AV_FRAME_DATA_PANSCAN,
    AV_FRAME_DATA_A53_CC,
    AV_FRAME_DATA_STEREO3D,
    AV_FRAME_DATA_MATRIXENCODING,
    AV_FRAME_DATA_DOWNMIX_INFO,
    AV_FRAME_DATA_REPLAYGAIN,
    AV_FRAME_DATA_DISPLAYMATRIX,
    AV_FRAME_DATA_AFD,
    AV_FRAME_DATA_MOTION_VECTORS,
    AV_FRAME_DATA_SKIP_SAMPLES,
    AV_FRAME_DATA_AUDIO_SERVICE_TYPE,
    AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
    AV_FRAME_DATA_GOP_TIMECODE,
    AV_FRAME_DATA_SPHERICAL,
    AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
    AV_FRAME_DATA_ICC_PROFILE,
    AV_FRAME_DATA_QP_TABLE_PROPERTIES,
    AV_FRAME_DATA_QP_TABLE_DATA,
    AV_FRAME_DATA_S12M_TIMECODE,
    AV_FRAME_DATA_DYNAMIC_HDR_PLUS,
    AV_FRAME_DATA_REGIONS_OF_INTEREST,
    AV_FRAME_DATA_VIDEO_ENC_PARAMS,
    AV_FRAME_DATA_SEI_UNREGISTERED,
    AV_FRAME_DATA_FILM_GRAIN_PARAMS,
    AV_FRAME_DATA_DETECTION_BBOXES,
    AV_FRAME_DATA_DOVI_RPU_BUFFER,
    AV_FRAME_DATA_DOVI_METADATA,
    AV_FRAME_DATA_DYNAMIC_HDR_VIVID

# Packets
proc av_packet_alloc*(): ptr AVPacket {.importc, header: "<libavcodec/packet.h>".}
proc av_packet_free*(pkt: ptr ptr AVPacket) {.importc, header: "<libavcodec/packet.h>".}
proc av_init_packet*(pkt: ptr AVPacket) {.importc, header: "<libavcodec/packet.h>".}
proc av_packet_unref*(pkt: ptr AVPacket) {.importc, cdecl.}
proc av_packet_ref*(dst: ptr AVPacket, src: ptr AVPacket): cint {.importc, header: "<libavcodec/packet.h>".}

# Frames
proc avcodec_send_packet*(avctx: ptr AVCodecContext, avpkt: ptr AVPacket): cint {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_receive_frame*(avctx: ptr AVCodecContext, frame: ptr AVFrame): cint {.importc, header: "<libavcodec/avcodec.h>".}
proc av_read_frame*(s: ptr AVFormatContext, pkt: ptr AVPacket): cint {.importc, cdecl.}
proc av_frame_alloc*(): ptr AVFrame {.importc, header: "<libavutil/frame.h>".}
proc av_frame_free*(frame: ptr ptr AVFrame) {.importc, header: "<libavutil/frame.h>".}
proc av_frame_unref*(frame: ptr AVFrame) {.importc, header: "<libavutil/frame.h>".}
proc av_frame_get_buffer*(frame: ptr AVFrame, align: cint): cint {.importc, header: "<libavutil/frame.h>".}
proc av_frame_is_writable*(frame: ptr AVFrame): cint {.importc, header: "<libavutil/frame.h>".}
proc av_frame_make_writable*(frame: ptr AVFrame): cint {.importc, header: "<libavutil/frame.h>".}

# Codec
proc avcodec_find_decoder*(codec_id: AVCodecID): ptr AVCodec {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_open2*(avctx: ptr AVCodecContext, codec: ptr AVCodec, options: ptr ptr AVDictionary): cint {.importc, header: "<libavcodec/avcodec.h>".}
proc avcodec_close*(avctx: ptr AVCodecContext): cint {.importc, header: "<libavcodec/avcodec.h>".}

# Error
proc AVERROR*(e: cint): cint {.inline.} = (-e)
const EAGAIN* = 11
const AVERROR_EOF* = AVERROR(0x10000051)

# FIFO
type
  AVAudioFifo* {.importc, header: "<libavutil/audio_fifo.h>".} = object

# Audio FIFO function declarations
proc av_audio_fifo_alloc*(sample_fmt: AVSampleFormat, channels: cint, nb_samples: cint): ptr AVAudioFifo {.importc, cdecl, header: "<libavutil/audio_fifo.h>".}
proc av_audio_fifo_free*(af: ptr AVAudioFifo) {.importc, cdecl.}
proc av_audio_fifo_write*(af: ptr AVAudioFifo, data: pointer, nb_samples: cint): cint {.importc, cdecl, header: "<libavutil/audio_fifo.h>".}
proc av_audio_fifo_read*(af: ptr AVAudioFifo, data: pointer, nb_samples: cint): cint {.importc, cdecl, header: "<libavutil/audio_fifo.h>".}
proc av_audio_fifo_size*(af: ptr AVAudioFifo): cint {.importc, cdecl.}
proc av_audio_fifo_drain*(af: ptr AVAudioFifo, nb_samples: cint): cint {.importc, cdecl.}
proc av_audio_fifo_reset*(af: ptr AVAudioFifo) {.importc, cdecl.}

proc av_get_bytes_per_sample*(sample_fmt: AVSampleFormat): cint {.importc, cdecl.}
proc av_samples_get_buffer_size*(linesize: ptr cint, nb_channels: cint, nb_samples: cint, sample_fmt: AVSampleFormat, align: cint): cint {.importc, header: "<libavutil/samplefmt.h>".}
