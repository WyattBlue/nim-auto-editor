# Package
version = "0.1.0"
author = "WyattBlue"
description = "Auto-Editor: Efficient media analysis and rendering"
license = "Unlicense"
srcDir = "src"
bin = @["main=auto-editor"]

# Dependencies
requires "nim >= 2.2.2"

# Tasks
task build, "Build the project in debug mode":
  exec "nim c -d:debug --out:auto-editor src/main.nim"

task make, "Export the project":
  exec "nim c -d:danger --passL:-s --out:auto-editor src/main.nim"

import os

task cleanff, "Remove":
  rmDir("ffmpeg_sources")
  rmDir("ffmpeg_build")

task makeFFmpeg, "Build FFmpeg from source":
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("ffmpeg_build")

  # Clone FFmpeg source
  cd "ffmpeg_sources"
  if not dirExists("ffmpeg"):
    exec "git clone -b n7.1.1 --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg"

  # Configure and build FFmpeg
  cd "ffmpeg"

  let configureCmd = """
  ./configure --prefix="../../ffmpeg_build" \
              --pkg-config-flags="--static" \
              --extra-cflags="-I../../ffmpeg_build/include" \
              --extra-ldflags="-L../../ffmpeg_build/lib" \
              --extra-libs="-lpthread -lm" \
              --enable-version3 \
              --enable-static \
              --disable-shared \
              --disable-ffplay \
              --disable-ffprobe \
              --disable-doc \
              --disable-network \
              --disable-indevs \
              --disable-outdevs \
              --disable-xlib \
              --disable-encoder=avui,dca,mlp,opus,s302m,sonic,sonic_ls,truehd,vorbis \
              --disable-decoder=sonic \
              --disable-autodetect
  """

  exec configureCmd

  # Detect number of CPU cores for parallel build
  when defined(macosx):
    exec "make -j$(sysctl -n hw.ncpu)"
  elif defined(linux):
    exec "make -j$(nproc)"
  elif defined(windows):
    exec "make -j%NUMBER_OF_PROCESSORS%"
  else:
    exec "make -j4" # Default to 4 cores

  exec "make install"
