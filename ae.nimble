# Package
version = "0.6.2"
author = "WyattBlue"
description = "Auto-Editor: Efficient media analysis and rendering"
license = "Unlicense"
srcDir = "src"
bin = @["main=auto-editor"]

# Dependencies
requires "nim >= 2.2.2"
requires "tinyre >= 1.6.0"
requires "checksums"

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
  --enable-filter=scale,format,gblur,aformat,abuffer,abuffersink,aresample,atempo,anull,anullsrc,volume \
  --enable-libmp3lame \
  --enable-libx264 \
  --disable-encoder={encodersDisabled} \
  --disable-decoder={decodersDisabled} \
  --disable-demuxer={demuxersDisabled} \
  --disable-muxer={muxersDisabled} \
"""

if defined(arm) or defined(arm64):
  commonFlags &= "  --enable-neon \\\n"

if defined(macosx):
  commonFlags &= "  --enable-videotoolbox \\\n"
  commonFlags &= "  --enable-audiotoolbox \\\n"

commonFlags &= "--disable-autodetect"

type Package = object
  name: string
  sourceUrl: string
  location: string
  sha256: string
  dirName: string
  buildArguments: seq[string]

let lame = Package(
  name: "lame",
  sourceUrl: "http://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz",
  location: "lame_3.100.orig.tar.gz",
  sha256: "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e",
  dirName: "lame-3.100",
  buildArguments: @["--disable-frontend", "--disable-decoder", "--disable-gtktest"],
)
let twolame = Package(
  name: "twolame",
  sourceUrl: "http://deb.debian.org/debian/pool/main/t/twolame/twolame_0.4.0.orig.tar.gz",
  location: "twolame_0.4.0.orig.tar.gz",
  dirName: "twolame-0.4.0",
  sha256: "cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d",
  buildArguments: @["--disable-sndfile"],
)
let x264 = Package(
  name: "x264",
  sourceUrl: "https://code.videolan.org/videolan/x264/-/archive/32c3b801191522961102d4bea292cdb61068d0dd/x264-32c3b801191522961102d4bea292cdb61068d0dd.tar.bz2",
  location: "x264-32c3b801191522961102d4bea292cdb61068d0dd.tar.bz2",
  dirName: "x264-32c3b801191522961102d4bea292cdb61068d0dd",
  sha256: "d7748f350127cea138ad97479c385c9a35a6f8527bc6ef7a52236777cf30b839",
  buildArguments: "--disable-cli --disable-lsmash --disable-swscale --disable-ffms --enable-strip".split(" "),
)
let ffmpeg = Package(
  name: "ffmpeg",
  sourceUrl: "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz",
  location: "ffmpeg-7.1.1.tar.xz",
  dirName: "ffmpeg-7.1.1",
  sha256: "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1",
)
let packages = @[lame, twolame, x264]

proc getFileHash(filename: string): string =
  let (existsOutput, existsCode) = gorgeEx("test -f " & filename)
  if existsCode != 0:
    raise newException(IOError, "File does not exist: " & filename)

  let (output, exitCode) = gorgeEx("shasum -a 256 " & filename)
  if exitCode != 0:
    raise newException(IOError, "Cannot hash file: " & filename)
  return output.split()[0]

proc checkHash(package: Package, filename: string) =
  let hash = getFileHash(filename)
  if package.sha256 != hash:
    echo filename
    echo &"sha256 hash of {package.name} tarball do not match!\nExpected: {package.sha256}\nGot: {hash}"
    quit(1)


proc makeInstall() =
  when defined(macosx):
    exec "make -j$(sysctl -n hw.ncpu)"
  elif defined(linux):
    exec "make -j$(nproc)"
  else:
    exec "make -j4"
  exec "make install"

proc ffmpegSetup() =
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("build")

  let buildPath = absolutePath("build")

  withDir "ffmpeg_sources":
    for package in @[ffmpeg] & packages:
      if not fileExists(package.location):
        exec &"curl -O -L {package.sourceUrl}"
        checkHash(package, "ffmpeg_sources" / package.location)

      var cmd: string = ""
      if package.name == "ffmpeg" and not dirExists(package.name):
        cmd =  &"tar -xJf {ffmpeg.location} && mv ffmpeg-7.1.1 ffmpeg"
      elif not dirExists(package.name):
        cmd = &"tar -xzf {package.location} && mv {package.dirName} {package.name}"

      if cmd != "":
        exec cmd
        let patchFile = &"../patches/{package.name}.patch"
        if fileExists(patchFile):
          cmd = &"patch -d {package.name} -i {absolutePath(patchFile)} -p1"
          echo "Applying patch: ", cmd
          exec cmd

      if package.name == "ffmpeg": # build later
        continue

      withDir package.name:
        if not fileExists("Makefile") or package.name == "x264":
          let cmd = &"./configure --prefix=\"{buildPath}\" --disable-shared --enable-static " & package.buildArguments.join(" ")
          echo "RUN: ", cmd
          exec cmd
        makeInstall()

proc ffmpegSetupWindows() =
  mkDir("ffmpeg_sources")
  mkDir("build")

  let buildPath = absolutePath("build")

  withDir "ffmpeg_sources":
    for package in packages:
      if not fileExists(package.location):
        exec &"curl -O -L {package.sourceUrl}"
        checkHash(package, "ffmpeg_sources" / package.location)

      if not dirExists(package.name):
        exec &"tar -xzf {package.location} && mv {package.dirName} {package.name}"

      withDir package.name:
        if not fileExists("Makefile"):
          var args = package.buildArguments
          args &= @[
            "--host=x86_64-w64-mingw32", "CC=x86_64-w64-mingw32-gcc",
            "CXX=x86_64-w64-mingw32-g++", "AR=x86_64-w64-mingw32-ar",
            "STRIP=x86_64-w64-mingw32-strip", "RANLIB=x86_64-w64-mingw32-ranlib"
          ]
          exec &"./configure --prefix=\"{buildPath}\" --disable-shared --enable-static " & args.join(" ")
        makeInstall()

    if not fileExists(ffmpeg.location):
      exec &"curl -O -L {ffmpeg.sourceUrl}"
      checkHash(ffmpeg, "ffmpeg_sources" / ffmpeg.location)

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

    makeInstall()

task makeffwin, "Build FFmpeg for Windows cross-compilation":
  ffmpegSetupWindows()

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
    makeInstall()

task windows, "Cross-compile to Windows (requires mingw-w64)":
  echo "Cross-compiling for Windows (64-bit)..."
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
