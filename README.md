**Auto-Editor** is a command line application for automatically **editing video and audio** using audio loudness.

This is Auto-Editor, written in the Nim programming language.

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

# Usage

Converting one timeline format to another:
```
auto-editor input.fcpxml --export premiere -o out.xml
```


The `info`, `desc`, and `subdump` commands work as expected:

```
auto-editor info example.mp4

example.mp4:
 - recommendedTimebase: 30/1
 - video:
   - track 0:
     - codec: h264
...
```

# Why Nim?
Nim produces a much smaller standalone binary than Python or pyinstaller. Nim is also faster thanks to its static typing.

## Building
You will need [the Nim compiler](https://nim-lang.org/), a Unix environment.

```
nimble makeffmpeg
nimble make
```

To install, just move the binary to a $PATH directory.
