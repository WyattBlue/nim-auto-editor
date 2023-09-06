**Auto-Editor** is a command line application for automatically **editing video and audio** using audio loudness.

This is Auto-Editor, written in the Nim programming language.

---

To use, just add the path to your unedited video.

```
auto-editor path/to/your/video.mp4
```

The only dependencies you need are ffmpeg and ffprobe.

## Why Nim?
Nim produces a much tinier standalone binary than Python w/ pyinstaller. Nim is faster and has a better type checker.

## How to Compile from Source
You will need [the Nim compiler](https://nim-lang.org/) and nimble.

```
nimble build -d:danger
```

## Todos
 - Feature parity with Python [auto-editor](https://github.com/WyattBlue/auto-editor)
 - Man pages
 - Tests
 - CI/CL