import std/os

import ../timeline
import ../ffmpeg
import audio


proc makeMedia*(tl: v3, tempDir: string, outputPath: string) =

#[
Python version for reference Only handle audio for now. Don't worry about ContainerRules.

from __future__ import annotations

import os
from fractions import Fraction
from heapq import heappop, heappush
from typing import TYPE_CHECKING

import av
from av import Codec

from auto_editor.render.audio import make_new_audio
from auto_editor.render.subtitle import make_new_subtitles
from auto_editor.render.video import render_av
from auto_editor.timeline import v3
from auto_editor.utils.bar import Bar
from auto_editor.utils.container import Container
from auto_editor.utils.log import Log

if TYPE_CHECKING:
    from auto_editor.__main__ import Args


class Priority:
    __slots__ = ("index", "frame_type", "frame", "stream")

    def __init__(self, tb: Fraction, value: int | Fraction, frame, stream):
        self.frame_type: str = stream.type
        assert self.frame_type in ("audio", "subtitle", "video")
        if self.frame_type in {"audio", "subtitle"}:
            self.index: int | float = round(value * frame.time_base * tb)
        else:
            self.index = float("inf") if value is None else int(value)
        self.frame = frame
        self.stream = stream

    def __lt__(self, other):
        return self.index < other.index

    def __eq__(self, other):
        return self.index == other.index


def make_media(
    args: Args, tl: v3, ctr: ContainerRules, output_path: str, log: Log, bar: Bar
) -> None:
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

    output = av.open(output_path, "w", container_options=options)

    # Setup video
    if ctr.default_vid not in ("none", "png") and tl.v:
        vframes = render_av(output, tl, args, log)
        output_stream: av.VideoStream | None
        output_stream = next(vframes)  # type: ignore
    else:
        output_stream, vframes = None, iter([])

    # Setup audio
    try:
        audio_encoder = Codec(args.audio_codec, "w")
    except av.FFmpegError as e:
        log.error(e)
    if audio_encoder.audio_formats is None:
        log.error(f"{args.audio_codec}: No known audio formats avail.")
    fmt = audio_encoder.audio_formats[0]

    audio_streams: list[av.AudioStream] = []

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
        subtitle_input = av.open(sub_path)
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
            should_get_sub = latest_sub_index <= earliest_video_index + MAX_SUB_AHEAD

        index, video_frame = next(vframes, (0, None))

        if video_frame:
            earliest_video_index = index
            heappush(frame_queue, Priority(tl.tb, index, video_frame, output_stream))

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
                heappush(frame_queue, Priority(tl.tb, aframe.pts, aframe, audio_stream))
        if should_get_sub:
            for subtitle_stream, packet in zip(subtitle_streams, subtitle_frames):
                if packet and packet.pts is not None:
                    packet.stream = subtitle_stream
                    heappush(frame_queue, Priority(tl.tb, packet.pts, packet, subtitle_stream))

        while frame_queue and frame_queue[0].index <= index:
            item = heappop(frame_queue)
            frame_type = item.frame_type
            bar_index = None
            try:
                if frame_type in ("video", "audio"):
                    if item.frame.time is not None:
                        bar_index = round(item.frame.time * tl.tb)
                    output.mux(item.stream.encode(item.frame))
                elif frame_type == "subtitle":
                    output.mux(item.frame)
            except av.error.ExternalError:
                log.error(
                    f"Generic error for encoder: {item.stream.name}\n"
                    f"at {item.index} time_base\nPerhaps video quality settings are too low?"
                )
            except av.FileNotFoundError:
                log.error(f"File not found: {output_path}")
            except av.FFmpegError as e:
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

