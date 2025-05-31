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

## Usage

While most of the intesrting
```
auto-editor info example.mp4
```

Make a timeline, this part is under the most active development.
```
auto-editor example.mp4
```

## Todos

### Subcommands
- [x] info
- [x] desc
- [ ] subdump
- [ ] levels

### Exporting
- [x] Final Cut Pro (.fcpxml)
- [ ] Premiere Pro (.xml)
- [ ] DaVinci Resolve
- [ ] ShotCut (.mlt)

### Editing Methods
- [x] "none"
- [ ] audio
- [ ] motion
- [ ] subtitle