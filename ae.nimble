# Package
version = "0.7.0"
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

type Package = object
  name: string
  sourceUrl: string
  sha256: string
  buildArguments: seq[string]
  buildSystem: string = "autoconf"

let lame = Package(
  name: "lame",
  sourceUrl: "http://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz",
  sha256: "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e",
  buildArguments: @["--disable-frontend", "--disable-decoder", "--disable-gtktest"],
)
let twolame = Package(
  name: "twolame",
  sourceUrl: "http://deb.debian.org/debian/pool/main/t/twolame/twolame_0.4.0.orig.tar.gz",
  sha256: "cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d",
  buildArguments: @["--disable-sndfile"],
)
let dav1d = Package(
  name: "dav1d",
  sourceUrl: "https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.bz2",
  sha256: "4eddffd108f098e307b93c9da57b6125224dc5877b1b3d157b31be6ae8f1f093",
  buildSystem: "meson",
)
let svtav1 = Package(
  name: "libsvtav1",
  sourceUrl: "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v3.1.0/SVT-AV1-v3.1.0.tar.bz2",
  sha256: "8231b63ea6c50bae46a019908786ebfa2696e5743487270538f3c25fddfa215a",
  buildSystem: "cmake",
)

let x264 = Package(
  name: "x264",
  sourceUrl: "https://code.videolan.org/videolan/x264/-/archive/32c3b801191522961102d4bea292cdb61068d0dd/x264-32c3b801191522961102d4bea292cdb61068d0dd.tar.bz2",
  sha256: "d7748f350127cea138ad97479c385c9a35a6f8527bc6ef7a52236777cf30b839",
  buildArguments: "--disable-cli --disable-lsmash --disable-swscale --disable-ffms --enable-strip".split(" "),
)
let ffmpeg = Package(
  name: "ffmpeg",
  sourceUrl: "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz",
  sha256: "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1",
)

func location(package: Package): string = # tar location
  package.sourceUrl.split("/")[^1]

func dirName(package: Package): string =
  var name = package.location
  for ext in [".orig.tar.gz", ".tar.xz", ".tar.bz2"]:
    if name.endsWith(ext):
      name = name[0..^ext.len+1]
      break
  return name.replace("_", "-")

let packages = @[lame, twolame, dav1d, svtav1, x264]

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

proc cmakeBuild(buildPath: string, crossWindows: bool = false) =
  mkDir("build_cmake")

  var cmakeArgs = @[
    &"-DCMAKE_INSTALL_PREFIX={buildPath}",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DBUILD_STATIC_LIBS=ON",
    "-DBUILD_APPS=OFF",
    "-DBUILD_DEC=OFF",
    "-DBUILD_ENC=ON",
    "-DENABLE_NASM=ON"
  ]

  if crossWindows:
    cmakeArgs.add("-DCMAKE_SYSTEM_NAME=Windows")
    cmakeArgs.add("-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc")
    cmakeArgs.add("-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++")
    cmakeArgs.add("-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres")
    cmakeArgs.add("-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER")
    cmakeArgs.add("-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY")
    cmakeArgs.add("-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY")

  withDir "build_cmake":
    let cmakeCmd = "cmake " & cmakeArgs.join(" ") & " .."
    echo "RUN: ", cmakeCmd
    exec cmakeCmd
    makeInstall()

proc mesonBuild(buildPath: string, crossWindows: bool = false) =
  mkDir("build_meson")

  var mesonArgs = @[
    &"--prefix={buildPath}",
    "--buildtype=release",
    "--default-library=static",
    "-Denable_docs=false",
    "-Denable_tools=false",
    "-Denable_examples=false",
    "-Denable_tests=false"
  ]

  if crossWindows:
    # Create cross-compilation file for meson
    let crossFile = "build_meson/meson-cross.txt"
    writeFile(crossFile, """
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
pkgconfig = 'x86_64-w64-mingw32-pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
""")
    mesonArgs.add("--cross-file=meson-cross.txt")

  withDir "build_meson":
    let mesonCmd = "meson setup " & mesonArgs.join(" ") & " .."
    echo "RUN: ", mesonCmd
    exec mesonCmd
    exec "ninja"
    exec "ninja install"

proc ffmpegSetup(crossWindows: bool) =
  # Create directories
  mkDir("ffmpeg_sources")
  mkDir("build")

  let buildPath = absolutePath("build")

  withDir "ffmpeg_sources":
    for package in @[ffmpeg] & packages:
      if not fileExists(package.location):
        exec &"curl -O -L {package.sourceUrl}"
        checkHash(package, "ffmpeg_sources" / package.location)

      var tarArgs = "xf"
      if package.location.endsWith("bz2"):
        tarArgs = "xjf"

      if not dirExists(package.name):
        exec &"tar {tarArgs} {package.location} && mv {package.dirName} {package.name}"
        let patchFile = &"../patches/{package.name}.patch"
        if fileExists(patchFile):
          let cmd = &"patch -d {package.name} -i {absolutePath(patchFile)} -p1"
          echo "Applying patch: ", cmd
          exec cmd

      if package.name == "ffmpeg": # build later
        continue

      withDir package.name:
        if package.buildSystem == "cmake":
          cmakeBuild(buildPath, crossWindows)
        elif package.buildSystem == "meson":
          mesonBuild(buildPath, crossWindows)
        else:
          if not fileExists("Makefile") or package.name == "x264":
            var args = package.buildArguments
            var envPrefix = ""
            if crossWindows:
              args.add("--host=x86_64-w64-mingw32")
              envPrefix = "CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ AR=x86_64-w64-mingw32-ar STRIP=x86_64-w64-mingw32-strip RANLIB=x86_64-w64-mingw32-ranlib "
            let cmd = &"{envPrefix}./configure --prefix=\"{buildPath}\" --disable-shared --enable-static " & args.join(" ")
            echo "RUN: ", cmd
            exec cmd
          makeInstall()


var commonFlags = &"""
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --disable-programs \
  --disable-doc \
  --disable-network \
  --disable-indevs \
  --disable-outdevs \
  --disable-xlib \
  --disable-filters \
  --enable-filter=scale,format,gblur,aformat,abuffer,abuffersink,aresample,atempo,anull,anullsrc,volume \
  --enable-libmp3lame \
  --enable-libdav1d \
  --enable-libsvtav1 \
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


proc setupDeps() =
  exec "pip install meson ninja"

task makeff, "Build FFmpeg from source":
  setupDeps()
  let buildPath = absolutePath("build")
  # Set PKG_CONFIG_PATH to include both standard and architecture-specific paths
  var pkgConfigPaths = @[buildPath / "lib/pkgconfig"]
  when defined(linux):
    pkgConfigPaths.add(buildPath / "lib/x86_64-linux-gnu/pkgconfig")
    pkgConfigPaths.add(buildPath / "lib64/pkgconfig")
  putEnv("PKG_CONFIG_PATH", pkgConfigPaths.join(":"))

  ffmpegSetup(crossWindows=false)

  # Configure and build FFmpeg
  withDir "ffmpeg_sources/ffmpeg":
    var ldflags = &"-L{buildPath}/lib"
    when defined(linux):
      ldflags &= &" -L{buildPath}/lib/x86_64-linux-gnu -L{buildPath}/lib64"
    exec &"""./configure --prefix="{buildPath}" \
      --pkg-config-flags="--static" \
      --extra-cflags="-I{buildPath}/include" \
      --extra-ldflags="{ldflags}" \
      --extra-libs="-lpthread -lm" \""" & "\n" & commonFlags
    makeInstall()

task makeffwin, "Build FFmpeg for Windows cross-compilation":
  setupDeps()
  let buildPath = absolutePath("build")
  putEnv("PKG_CONFIG_PATH", buildPath / "lib/pkgconfig")

  ffmpegSetup(crossWindows=true)

  # Configure and build FFmpeg with MinGW
  withDir "ffmpeg_sources/ffmpeg":
    var ldflags = &"-L{buildPath}/lib"
    when defined(linux):
      ldflags &= &" -L{buildPath}/lib/x86_64-linux-gnu -L{buildPath}/lib64"
    exec (&"""CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ AR=x86_64-w64-mingw32-ar STRIP=x86_64-w64-mingw32-strip RANLIB=x86_64-w64-mingw32-ranlib ./configure --prefix="{buildPath}" \
      --pkg-config-flags="--static" \
      --extra-cflags="-I{buildPath}/include" \
      --extra-ldflags="{ldflags}" \
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
