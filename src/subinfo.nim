import osproc

# type
#   VideoStream = object
#     width: uint64
#     height: uint64
#     codec: string
#     duration: string
#     fps: Rational[int64]
#     sar: string #
#     color_range: string
#     color_space: string
#     color_primaries: string
#     bitrate: string
#     lang: string


# Info subcommand code
# TODO: "ffprobe" literal needs to be replaced

proc info(osargs: seq[string]) =
    let ffout = execProcess("ffprobe",
        args=["-v", "-8", "-show_streams", "-show_format", osargs[1]],
        options={poUsePath}
    )
    echo ffout

export info