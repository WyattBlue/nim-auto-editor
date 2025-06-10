**Auto-Editor** is a command line application for automatically **editing video and audio** using audio loudness.

This is Auto-Editor, written in the Nim programming language.

---

## Why Nim?
Nim produces a much smaller standalone binary than Python or pyinstaller. Nim is also faster thanks to its static typing.

## Building
You will need [the Nim compiler](https://nim-lang.org/), a Unix environment.

```
nimble makeffmpeg
nimble make
```

To install, just move the binary to a $PATH directory.

## Usage

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

Converting one timeline format to another:
```
auto-editor input.fcpxml --export premiere -o out.xml
```

Make a timeline, this part is under the most active development.
```
auto-editor example.mp4
```

## Todos

### Subcommands
- [x] info
- [x] desc
- [x] subdump
- [x] levels
- [x] cache

### Exporting
- [x] Final Cut Pro (.fcpxml)
- [x] ShotCut (.mlt)
- [x] Premiere Pro (.xml)
- [x] DaVinci Resolve
- [ ] Media file
- [ ] Clip sequence

### Editing Procedures
- [x] "none"
- [x] audio
- [ ] motion
- [ ] subtitle
- [ ] or
- [ ] and