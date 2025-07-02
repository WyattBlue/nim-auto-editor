import std/os

import ../timeline
import ../ffmpeg
import audio


proc makeMedia*(tl: v3, tempDir: string, outputPath: string) =
  if tl.a.len > 0:
    let audioPaths = makeNewAudio(tl, tempDir)
    if audioPaths.len > 0:
      if audioPaths.len == 1:
        copyFile(audioPaths[0], outputPath)
      else:
        mixAudioFiles(tl.sr, audioPaths, outputPath)


#[
Python version for reference:
Only do one audio stream.


def edit_media(paths: list[str], args: Args, log: Log) -> None:
    bar = initBar(args.progress)
    tl = src = use_path = None

    if paths:
        path_ext = splitext(paths[0])[1].lower()
        if path_ext == ".xml":
            from auto_editor.imports.fcp7 import fcp7_read_xml

            tl = fcp7_read_xml(paths[0], log)
        elif path_ext == ".mlt":
            log.error("Reading mlt files not implemented")
        elif path_ext in {".v1", ".v3", ".json"}:
            from auto_editor.imports.json import read_json

            tl = read_json(paths[0], log)
        else:
            sources = [FileInfo.init(path, log) for path in paths]
            src = sources[0]
            use_path = src.path

    if args.export is None:
        output, export = set_output(args.output, args.export, use_path, log)
        export_ops: dict[str, Any] = {"export": export}
    else:
        export_ops = parse_export(args.export, log)
        export = export_ops["export"]
        output, _ = set_output(args.output, export, use_path, log)

    if output == "-":
        # When printing to stdout, silence all logs.
        log.quiet = True

    if not args.preview:
        log.conwrite("Starting")

        if os.path.isdir(output):
            log.error("Output path already has an existing directory!")

    if args.sample_rate is None:
        if tl is None:
            samplerate = 48000 if src is None else src.get_sr()
        else:
            samplerate = tl.sr
    else:
        samplerate = args.sample_rate

    if tl is None:
        tl = make_timeline(sources, args, samplerate, bar, log)
    else:
        if args.resolution is not None:
            tl.T.res = args.resolution
        if args.background is not None:
            tl.background = args.background
        if args.frame_rate is not None:
            log.warning(
                "Setting timebase/framerate is not supported when importing timelines"
            )

    if args.preview:
        from auto_editor.preview import preview

        preview(tl, log)
        return

    if export in {"v1", "v3"}:
        from auto_editor.exports.json import make_json_timeline

        make_json_timeline(export, output, tl, log)
        return

    if export in {"premiere", "resolve-fcp7"}:
        from auto_editor.exports.fcp7 import fcp7_write_xml

        is_resolve = export.startswith("resolve")
        fcp7_write_xml(export_ops["name"], output, is_resolve, tl)
        return

    if export == "final-cut-pro":
        from auto_editor.exports.fcp11 import fcp11_write_xml

        ver = export_ops["version"]
        fcp11_write_xml(export_ops["name"], ver, output, False, tl, log)
        return

    if export == "resolve":
        from auto_editor.exports.fcp11 import fcp11_write_xml

        set_stream_to_0(tl, log)
        fcp11_write_xml(export_ops["name"], 10, output, True, tl, log)
        return

    if export == "shotcut":
        from auto_editor.exports.shotcut import shotcut_write_mlt

        shotcut_write_mlt(output, tl)
        return

    if output == "-":
        log.error("Exporting media files to stdout is not supported.")
    out_ext = splitext(output)[1].replace(".", "")

    # Check if export options make sense.
    ctr = container_constructor(out_ext.lower(), log)

    if ctr.samplerate is not None and args.sample_rate not in ctr.samplerate:
        log.error(f"'{out_ext}' container only supports samplerates: {ctr.samplerate}")

    args.video_codec = set_video_codec(args.video_codec, src, out_ext, ctr, log)
    args.audio_codec = set_audio_codec(args.audio_codec, src, out_ext, ctr, log)

    def make_media(tl: v3, output_path: str) -> None:
        options = {}
        mov_flags = []
        if args.fragmented and not args.no_fragmented:
            mov_flags.extend(["default_base_moof", "frag_keyframe", "separate_moof"])
            options["frag_duration"] = "0.2"
            if args.faststart:
                log.warning("Fragmented is enabled, will not apply faststart.")
        elif not args.no_faststart:
            mov_flags.append("faststart")
        if mov_flags:
            options["movflags"] = "+".join(mov_flags)

        output = bv.open(output_path, "w", container_options=options)

        # Setup video
        if ctr.default_vid not in ("none", "png") and tl.v:
            vframes = render_av(output, tl, args, log)
            output_stream: bv.VideoStream | None
            output_stream = next(vframes)  # type: ignore
        else:
            output_stream, vframes = None, iter([])

        # Setup audio
        try:
            audio_encoder = bv.Codec(args.audio_codec, "w")
        except bv.FFmpegError as e:
            log.error(e)
        if audio_encoder.audio_formats is None:
            log.error(f"{args.audio_codec}: No known audio formats avail.")
        fmt = audio_encoder.audio_formats[0]

        audio_streams: list[bv.AudioStream] = []

        if ctr.default_aud == "none":
            while len(tl.a) > 0:
                tl.a.pop()
        elif len(tl.a) > 1 and ctr.max_audios == 1:
            log.warning("Dropping extra audio streams (container only allows one)")

            while len(tl.a) > 1:
                tl.a.pop()

        if len(tl.a) > 0:
            audio_streams, audio_gen_frames = make_new_audio(output, fmt, tl, args, log)
        else:
            audio_streams, audio_gen_frames = [], [iter([])]

        # Setup subtitles
        if ctr.default_sub != "none" and not args.sn:
            sub_paths = make_new_subtitles(tl, log)
        else:
            sub_paths = []

        subtitle_streams = []
        subtitle_inputs = []
        sub_gen_frames = []

        for i, sub_path in enumerate(sub_paths):
            subtitle_input = bv.open(sub_path)
            subtitle_inputs.append(subtitle_input)
            subtitle_stream = output.add_stream_from_template(
                subtitle_input.streams.subtitles[0]
            )
            if i < len(tl.T.subtitles) and (lang := tl.T.subtitles[i].lang) is not None:
                subtitle_stream.metadata["language"] = lang

            subtitle_streams.append(subtitle_stream)
            sub_gen_frames.append(subtitle_input.demux(subtitles=0))

        no_color = log.no_color or log.machine
        encoder_titles = []
        if output_stream is not None:
            name = output_stream.codec.canonical_name
            encoder_titles.append(name if no_color else f"\033[95m{name}")
        if audio_streams:
            name = audio_streams[0].codec.canonical_name
            encoder_titles.append(name if no_color else f"\033[96m{name}")
        if subtitle_streams:
            name = subtitle_streams[0].codec.canonical_name
            encoder_titles.append(name if no_color else f"\033[32m{name}")

        title = f"({os.path.splitext(output_path)[1][1:]}) "
        if no_color:
            title += "+".join(encoder_titles)
        else:
            title += "\033[0m+".join(encoder_titles) + "\033[0m"
        bar.start(tl.end, title)

        MAX_AUDIO_AHEAD = 30  # In timebase, how far audio can be ahead of video.
        MAX_SUB_AHEAD = 30

        class Priority:
            __slots__ = ("index", "frame_type", "frame", "stream")

            def __init__(self, value: int | Fraction, frame, stream):
                self.frame_type: str = stream.type
                assert self.frame_type in ("audio", "subtitle", "video")
                if self.frame_type in {"audio", "subtitle"}:
                    self.index: int | float = round(value * frame.time_base * tl.tb)
                else:
                    self.index = float("inf") if value is None else int(value)
                self.frame = frame
                self.stream = stream

            def __lt__(self, other):
                return self.index < other.index

            def __eq__(self, other):
                return self.index == other.index

        # Priority queue for ordered frames by time_base.
        frame_queue: list[Priority] = []
        latest_audio_index = float("-inf")
        latest_sub_index = float("-inf")
        earliest_video_index = None

        while True:
            if earliest_video_index is None:
                should_get_audio = True
                should_get_sub = True
            else:
                for item in frame_queue:
                    if item.frame_type == "audio":
                        latest_audio_index = max(latest_audio_index, item.index)
                    elif item.frame_type == "subtitle":
                        latest_sub_index = max(latest_sub_index, item.index)

                should_get_audio = (
                    latest_audio_index <= earliest_video_index + MAX_AUDIO_AHEAD
                )
                should_get_sub = (
                    latest_sub_index <= earliest_video_index + MAX_SUB_AHEAD
                )

            index, video_frame = next(vframes, (0, None))

            if video_frame:
                earliest_video_index = index
                heappush(frame_queue, Priority(index, video_frame, output_stream))

            if should_get_audio:
                audio_frames = [next(frames, None) for frames in audio_gen_frames]
                if output_stream is None and audio_frames and audio_frames[-1]:
                    assert audio_frames[-1].time is not None
                    index = round(audio_frames[-1].time * tl.tb)
            else:
                audio_frames = [None]
            if should_get_sub:
                subtitle_frames = [next(packet, None) for packet in sub_gen_frames]
            else:
                subtitle_frames = [None]

            # Break if no more frames
            if (
                all(frame is None for frame in audio_frames)
                and video_frame is None
                and all(packet is None for packet in subtitle_frames)
            ):
                break

            if should_get_audio:
                for audio_stream, aframe in zip(audio_streams, audio_frames):
                    if aframe is None:
                        continue
                    assert aframe.pts is not None
                    heappush(frame_queue, Priority(aframe.pts, aframe, audio_stream))
            if should_get_sub:
                for subtitle_stream, packet in zip(subtitle_streams, subtitle_frames):
                    if packet and packet.pts is not None:
                        packet.stream = subtitle_stream
                        heappush(
                            frame_queue, Priority(packet.pts, packet, subtitle_stream)
                        )

            while frame_queue and frame_queue[0].index <= index:
                item = heappop(frame_queue)
                frame_type = item.frame_type
                bar_index = None
                try:
                    if frame_type in {"video", "audio"}:
                        if item.frame.time is not None:
                            bar_index = round(item.frame.time * tl.tb)
                        output.mux(item.stream.encode(item.frame))
                    elif frame_type == "subtitle":
                        output.mux(item.frame)
                except bv.error.ExternalError:
                    log.error(
                        f"Generic error for encoder: {item.stream.name}\n"
                        f"at {item.index} time_base\nPerhaps video quality settings are too low?"
                    )
                except bv.FileNotFoundError:
                    log.error(f"File not found: {output_path}")
                except bv.FFmpegError as e:
                    log.error(e)

                if bar_index:
                    bar.tick(bar_index)

        # Flush streams
        if output_stream is not None:
            output.mux(output_stream.encode(None))
        for audio_stream in audio_streams:
            output.mux(audio_stream.encode(None))

        bar.end()

        # Close resources
        for subtitle_input in subtitle_inputs:
            subtitle_input.close()
        output.close()
]#

