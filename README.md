**Auto-Editor** is a command line application for automatically **editing video and audio** using audio loudness.

This is Auto-Editor, written in the Nim programming language.

---

To use, just add the path to your unedited video.

```
auto-editor path/to/your/video.mp4
```

The only dependencies you need are ffmpeg and ffprobe.

## How to Compile

```
cd src/
nim c -d:danger auto_editor
```