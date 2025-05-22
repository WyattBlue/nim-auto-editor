# Package
version = "0.2.0"
author = "WyattBlue"
description = "Auto-Editor: Efficient media analysis and rendering"
license = "Unlicense"
srcDir = "src"
bin = @["main=auto-editor"]

# Dependencies
requires "nim >= 2.2.2"

# Tasks
import os

task build, "Build the project in debug mode":
  exec "nim c -d:debug --out:auto-editor src/main.nim"

task make, "Export the project":
  exec "nim c -d:danger --out:auto-editor src/main.nim"
  when defined(macosx):
    exec "strip -ur auto-editor"


task cleanff, "Remove":
  rmDir("ffmpeg_sources")
  rmDir("ffmpeg_build")

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

  exec """./configure --prefix="../../ffmpeg_build" \
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
    --disable-autodetect \
    --arch=x86_64 \
    --target-os=mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-cross-compile
  """

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
         "--passL:-lbcrypt " &  # Add Windows Bcrypt library
         "--passL:-static " &
         "--out:auto-editor.exe src/main.nim"
