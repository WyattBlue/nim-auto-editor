<p align="center"><img src="https://auto-editor.com/img/auto-editor-banner.webp" title="Auto-Editor" width="700"></p>

**Auto-Editor** is a command line application for automatically **editing video and audio** by analyzing a variety of methods, most notably audio loudness.

---

Before doing the real editing, you first cut out the "dead space" which is typically silence. This is known as a "first pass". Cutting these is a boring task, especially if the video is very long.

```
auto-editor path/to/your/video.mp4
```

# Installation

## Release Files

File|Description
:---|:---
[auto-editor-windows-amd64.exe](https://github.com/WyattBlue/nim-auto-editor/releases/latest/download/auto-editor-windows-amd64.exe)|Windows standlone amd64 executable (a.k.a x86_64)
[auto-editor-macos-arm64](https://github.com/WyattBlue/nim-auto-editor/releases/latest/download/auto-editor-macos-arm64)|MacOS standalone ARM executable
[auto-editor-macos-x86_64](https://github.com/WyattBlue/nim-auto-editor/releases/latest/download/auto-editor-macos-x86_64)|MacOS standalone x86_64 executable
[auto-editor-linux](https://github.com/WyattBlue/nim-auto-editor/releases/latest/download/auto-editor-linux-x86_64)|Linux standalone x86_64 binary


<h2 align="center">Cutting</h2>

Change the **pace** of the edited video by using `--margin`.

`--margin` adds in some "silent" sections to make the editing feel nicer.

```
# Add 0.2 seconds of padding before and after to make the edit nicer.
# `0.2s` is the default value for `--margin`
auto-editor example.mp4 --margin 0.2sec

# Add 0.3 seconds of padding before, 1.5 seconds after
auto-editor example.mp4 --margin 0.3s,1.5sec
```

### See What Auto-Editor Cuts Out
To export what auto-editor normally cuts out. Set `--video-speed` to `99999` and `--silent-speed` to `1`. This is the reverse of the usual default values.

```
auto-editor example.mp4 --video-speed 99999 --silent-speed 1
```

<h2 align="center">Exporting to Editors</h2>

Create an XML file that can be imported to Adobe Premiere Pro using this command:

```
auto-editor example.mp4 --export premiere
```

Auto-Editor can also export to:
- DaVinci Resolve with `--export resolve`
- Final Cut Pro with `--export final-cut-pro`
- ShotCut with `--export shotcut`
- Individual media clips with `--export clip-sequence`


## Building
You will need [the Nim compiler](https://nim-lang.org/), a Unix environment.

```
nimble makeff
nimble make
```

To install, just move the binary to a $PATH directory.
