import std/strformat
import std/xmltree
import std/sets
import std/os
import std/algorithm

import ../media
import ../log
import ../ffmpeg
import ../timeline

#[
Export a FCPXML 11 file readable with Final Cut Pro 10.6.8 or later.

See docs here:
https://developer.apple.com/documentation/professional_video_applications/fcpxml_reference

]#


func get_colorspace(src: MediaInfo): string =
    # See: https://developer.apple.com/documentation/professional_video_applications/fcpxml_reference/asset#3686496

    if src.v.len == 0:
        return "1-1-1 (Rec. 709)"

    let s = src.v[0]
    if s.pix_fmt == "rgb24":
        return "sRGB IEC61966-2.1"
    if s.color_space == 5: # "bt470bg"
        return "5-1-6 (Rec. 601 PAL)"
    if s.color_space == 6: # "smpte170m"
        return "6-1-6 (Rec. 601 NTSC)"
    if s.color_primaries == 9: # "bt2020"
        # See: https://video.stackexchange.com/questions/22059/how-to-identify-hdr-video
        if s.color_transfer == 16 or s.color_transfer == 18: # "smpte2084" "arib-std-b67"
            return "9-18-9 (Rec. 2020 HLG)"
        return "9-1-9 (Rec. 2020)"

    return "1-1-1 (Rec. 709)"


func make_name(src: MediaInfo, tb: AVRational): string =
    if src.get_res()[1] == 720 and tb == 30:
        return "FFVideoFormat720p30"
    if src.get_res()[1] == 720 and tb == 25:
        return "FFVideoFormat720p25"
    return "FFVideoFormatRateUndefined"

func pathToUri(a: string): string =
    return "file://" & a

proc fcp11_write_xml*(groupName: string, version: int, output: string,
        resolve: bool, tl: v3) =
    func fraction(val: int): string =
        if val == 0:
            return "0s"
        return &"{val.cint * tl.tb.den}/{tl.tb.num}s"

    var verStr: string
    if version == 11:
        verStr = "1.11"
    elif version == 10:
        verStr = "1.10"
    else:
        error(&"Unknown final cut pro version: {version}")

    let fcpxml = <>fcpxml(version = verStr)

    let resources = newElement("resources")
    fcpxml.add(resources)

    var src_dur = 0
    var tl_dur = (if resolve: 0 else: tl.len)
    var proj_name: string

    var i = 0
    for ptrSrc in tl.uniqueSources:
        let one_src = initMediaInfo(ptrSrc[])

        if i == 0:
            proj_name = splitFile(one_src.path).name
            src_dur = int(one_src.duration * tl.tb)
            if resolve:
                tl_dur = src_dur

        let id = "r" & $(i * 2 + 1)
        let width = $tl.res[0]
        let height = $tl.res[1]
        resources.add(<>format(id = id, name = make_name(one_src, tl.tb),
                frameDuration = fraction(1), width = width, height = height,
                colorSpace = get_colorspace(one_src)))

        let id2 = "r" & $(i * 2 + 2)
        let hasVideo = (if one_src.v.len > 0: "1" else: "0")
        let hasAudio = (if one_src.a.len > 0: "1" else: "0")
        let audioChannels = (if one_src.a.len == 0: "2" else: $one_src.a[0].channels)

        let r2 = <>asset(id = id2, name = splitFile(one_src.path).name,
                start = "0s", hasVideo = hasVideo, format = id,
                hasAudio = hasAudio, audioSources = "1",
                audioChannels = audioChannels, duration = fraction(tl_dur))

        let mediaRep = newElement("media-rep")
        mediaRep.attrs = {"kind": "original-media",
                "src": one_src.path.absolutePath().pathToUri()}.toXmlAttributes

        r2.add mediaRep
        resources.add r2

        i += 1

    let lib = <>library()
    let evt = <>event(name = group_name)
    let proj = <>project(name = proj_name)
    let sequence = <>sequence(format = "r1", tcStart = "0s", tcFormat = "NDF",
            audioLayout = tl.layout, audioRate = (if tl.sr ==
            44100: "44.1k" else: "48k"))
    let spine = <>spine()

    sequence.add spine
    proj.add sequence
    evt.add proj
    lib.add evt
    fcpxml.add lib

    proc make_clip(`ref`: string, clip: Clip) =
        let clip_properties = {
            "name": proj_name,
            "ref": `ref`,
            "offset": fraction(clip.start),
            "duration": fraction(clip.dur),
            "start": fraction(clip.offset),
            "tcFormat": "NDF"
        }.toXmlAttributes

        let asset = <>asset_clip()
        asset.attrs = clip_properties
        spine.add(asset)

        if clip.speed != 1:
            # See the "Time Maps" section.
            # https://developer.apple.com/documentation/professional_video_applications/fcpxml_reference/story_elements/timemap/

            let timemap = newElement("timeMap")
            let timept1 = newElement("timept")
            timept1.attrs = {"time": "0s", "value": "0s",
                    "interp": "smooth2"}.toXmlAttributes
            timemap.add(timept1)

            let timept2 = newElement("timept")
            timept2.attrs = {
                "time": fraction(int(src_dur.float / clip.speed)),
                "value": fraction(src_dur),
                "interp": "smooth2"
            }.toXmlAttributes
            timemap.add(timept2)

            asset.add(timemap)

    var clips: seq[Clip] = @[]
    if tl.v.len > 0 and tl.v[0].len > 0:
        clips = tl.v[0]
    elif tl.a.len > 0 and tl.a[0].len > 0:
        clips = tl.a[0]

    var all_refs: seq[string] = @["r2"]
    if resolve:
        for i in 1 ..< tl.a.len:
            all_refs.add("r" & $((i + 1) * 2))

    for my_ref in all_refs.reversed:
        for clip in clips:
            make_clip(my_ref, clip)

    if output == "-":
        echo $fcpxml
    else:
        let xmlStr = "<?xml version='1.0' encoding='utf-8'?>\n" & $fcpxml
        writeFile(output, xmlStr)
