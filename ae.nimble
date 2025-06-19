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

task make, "Export the project":
  exec "nim c -d:danger --out:auto-editor src/main.nim"
  when defined(macosx):
    exec "strip -ur auto-editor"
  when defined(linux):
    exec "strip -s auto-editor"

task cleanff, "Remove":
  rmDir("ffmpeg_sources")
  rmDir("build")

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
  --enable-libmp3lame \
  --disable-encoder={encodersDisabled} \
  --disable-decoder={decodersDisabled} \
  --disable-demuxer={demuxersDisabled} \
  --disable-muxer={muxersDisabled} \
"""

if defined(arm) or defined(arm64):
  commonFlags &= "  --enable-neon \\\n"

commonFlags &= "--disable-autodetect"

type Package = object
  name: string
  sourceUrl: string
  location: string
  sha256: string

let lame = Package(
  name: "lame",
  sourceUrl: "http://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz",
  location: "lame_3.100.orig.tar.gz",
)
let ffmpeg = Package(
  name: "ffmpeg",
  sourceUrl: "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz",
  location: "ffmpeg-7.1.1.tar.xz",
)

proc ffmpegSetup() =
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("build")

  # Get absolute path for build
  let buildPath = absolutePath("build")

  withDir "ffmpeg_sources":
    # Download and extract LAME
    if not fileExists(lame.location):
      exec &"curl -O -L {lame.sourceUrl}"
    if not dirExists(lame.name):
      exec &"tar -xzf {lame.location} && mv lame-3.100 lame"

    # Build LAME
    withDir "lame":
      if not fileExists("Makefile"):
        exec &"""./configure --prefix="{buildPath}" \
          --disable-shared \
          --enable-static \
          --disable-frontend \
          --disable-decoder \
          --disable-gtktest"""

      when defined(macosx):
        exec "make -j$(sysctl -n hw.ncpu)"
      elif defined(linux):
        exec "make -j$(nproc)"
      else:
        exec "make -j4"

      exec "make install"

    # Download and extract FFmpeg
    if not fileExists(ffmpeg.location):
      exec &"curl -O -L {ffmpeg.sourceUrl}"
    if not dirExists(ffmpeg.name):
      exec &"tar -xJf {ffmpeg.location} && mv ffmpeg-7.1.1 ffmpeg"

proc ffmpegSetupWindows() =
  mkDir("ffmpeg_sources")
  mkDir("build")

  # Get absolute path for build
  let buildPath = absolutePath("build")

  withDir "ffmpeg_sources":
    # Download and extract LAME
    if not fileExists(lame.location):
      exec &"curl -O -L {lame.sourceUrl}"
    if not dirExists(lame.name):
      exec &"tar -xzf {lame.location} && mv lame-3.100 lame"

    # Build LAME for Windows cross-compilation
    withDir "lame":
      if not fileExists("Makefile"):
        exec &"""./configure --prefix="{buildPath}" \
          --host=x86_64-w64-mingw32 \
          --disable-shared \
          --enable-static \
          --disable-frontend \
          --disable-decoder \
          --disable-gtktest \
          CC=x86_64-w64-mingw32-gcc \
          CXX=x86_64-w64-mingw32-g++ \
          AR=x86_64-w64-mingw32-ar \
          STRIP=x86_64-w64-mingw32-strip \
          RANLIB=x86_64-w64-mingw32-ranlib"""

      when defined(linux):
        exec "make -j$(nproc)"
      else:
        exec "make -j4"

      exec "make install"

    # Download and extract FFmpeg
    if not fileExists(ffmpeg.location):
      exec &"curl -O -L {ffmpeg.sourceUrl}"
    if not dirExists(ffmpeg.name):
      exec &"tar -xJf {ffmpeg.location} && mv ffmpeg-7.1.1 ffmpeg"

task makeff, "Build FFmpeg from source":
  ffmpegSetup()

  # Get absolute path for build
  let buildPath = absolutePath("build")

  # Configure and build FFmpeg
  withDir "ffmpeg_sources/ffmpeg":
    exec &"""./configure --prefix="{buildPath}" \
      --pkg-config-flags="--static" \
      --extra-cflags="-I{buildPath}/include" \
      --extra-ldflags="-L{buildPath}/lib" \
      --extra-libs="-lpthread -lm" \""" & "\n" & commonFlags

    when defined(macosx):
      exec "make -j$(sysctl -n hw.ncpu)"
    elif defined(linux):
      exec "make -j$(nproc)"
    else:
      exec "make -j4"

    exec "make install"

task makeffwin, "Build FFmpeg for Windows cross-compilation":
  ffmpegSetupWindows()

  # Get absolute path for build
  let buildPath = absolutePath("build")

  # Configure and build FFmpeg with MinGW
  withDir "ffmpeg_sources/ffmpeg":
    exec (&"""./configure --prefix="{buildPath}" \
      --pkg-config-flags="--static" \
      --extra-cflags="-I{buildPath}/include" \
      --extra-ldflags="-L{buildPath}/lib" \
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
  if not dirExists("build"):
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
