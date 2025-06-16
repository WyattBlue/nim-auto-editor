# Package
version = "0.5.2"
author = "WyattBlue"
description = "Auto-Editor: Efficient media analysis and rendering"
license = "Unlicense"
srcDir = "src"
bin = @["main=auto-editor"]

# Dependencies
requires "nim >= 2.2.2"
requires "tinyre >= 1.6.0"

# Tasks
import std/os
import std/[strutils, strformat]

task test, "Test the project":
  exec "nim c -r tests/rationals"

task build, "Build the project in debug mode":
  exec "nim c -d:debug --out:auto-editor src/main.nim"

task make, "Export the project":
  exec "nim c -d:danger --out:auto-editor src/main.nim"
  when defined(macosx):
    exec "strip -ur auto-editor"
  when defined(linux):
    exec "strip -s auto-editor"


task cleanff, "Remove":
  rmDir("ffmpeg_sources")
  rmDir("ffmpeg_build")

var disableDecoders: seq[string] = @[]
var disableEncoders: seq[string] = @[]
var disableDemuxers: seq[string] = @[]
var disableMuxers: seq[string] = @[]

# Marked as 'Experimental'
disableDecoders.add "sonic"
disableEncoders &= "avui,dca,mlp,opus,s302m,sonic,sonic_ls,truehd,vorbis".split(",")

# Technically obsolete
disableDecoders.add "flv"
disableEncoders.add "flv"
disableMuxers.add "flv"
disableDemuxers &= @["flv", "live_flv", "kux"]

let encodersDisabled = disableEncoders.join(",")
let decodersDisabled = disableDecoders.join(",")
let demuxersDisabled = disableDemuxers.join(",")
let muxersDisabled = disableMuxers.join(",")

var commonFlags = &"""
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --disable-programs \
  --disable-doc \
  --disable-network \
  --disable-bsfs \
  --disable-indevs \
  --disable-outdevs \
  --disable-xlib \
  --disable-filters \
  --enable-filter=scale,format,gblur \
  --disable-encoders \
  --disable-encoder={encodersDisabled} \
  --enable-encoder=pcm_s16le \
  --disable-decoder={decodersDisabled} \
  --disable-demuxer={demuxersDisabled} \
  --disable-muxer={muxersDisabled} \
"""

if defined(arm) or defined(arm64):
  commonFlags &= "  --enable-neon \\\n"

commonFlags &= "--disable-autodetect"

task makeff, "Build FFmpeg from source":
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("ffmpeg_build")

  # Clone FFmpeg source
  cd "ffmpeg_sources"
  if not dirExists("ffmpeg"):
    exec "git clone -b n7.1.1 --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg"

  # Configure and build FFmpeg
  cd "ffmpeg"

  exec """./configure --prefix="../../ffmpeg_build" \
    --pkg-config-flags="--static" \
    --extra-cflags="-I../../ffmpeg_build/include" \
    --extra-ldflags="-L../../ffmpeg_build/lib" \
    --extra-libs="-lpthread -lm" \""" & "\n" & commonFlags

  when defined(macosx):
    exec "make -j$(sysctl -n hw.ncpu)"
  elif defined(linux):
    exec "make -j$(nproc)"
  else:
    exec "make -j4"

  exec "make install"

task makeffwin, "Build FFmpeg for Windows cross-compilation":
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("ffmpeg_build")

  # Clone FFmpeg source
  cd "ffmpeg_sources"
  if not dirExists("ffmpeg"):
    exec "git clone -b n7.1.1 --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg"

  # Configure and build FFmpeg with MinGW
  cd "ffmpeg"

  exec ("""./configure --prefix="../../ffmpeg_build" \
    --pkg-config-flags="--static" \
    --extra-cflags="-I../../ffmpeg_build/include" \
    --extra-ldflags="-L../../ffmpeg_build/lib" \
    --extra-libs="-lpthread -lm" \
    --arch=x86_64 \
    --target-os=mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-cross-compile \""" & "\n" & commonFlags)

  # Build with multiple cores
  when defined(linux):
    exec "make -j$(nproc)"
  else:
    exec "make -j4" # Default to 4 cores

  exec "make install"

task windows, "Cross-compile to Windows (requires mingw-w64)":
  echo "Cross-compiling for Windows (64-bit)..."
  # First, make sure FFmpeg is built for Windows
  if not dirExists("ffmpeg_build"):
    echo "FFmpeg for Windows not found. Run 'nimble makeffwin' first."
  else:
    exec "nim c -d:danger --os:windows --cpu:amd64 --cc:gcc " &
         "--gcc.exe:x86_64-w64-mingw32-gcc " &
         "--gcc.linkerexe:x86_64-w64-mingw32-gcc " &
         "--passL:-lbcrypt " & # Add Windows Bcrypt library
         "--passL:-static " &
         "--out:auto-editor.exe src/main.nim"
    
    # Strip the Windows binary
    exec "x86_64-w64-mingw32-strip -s auto-editor.exe"

