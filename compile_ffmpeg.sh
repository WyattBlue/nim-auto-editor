#!/bin/bash

# Create a directory for FFmpeg source and build
mkdir -p ffmpeg_sources ffmpeg_build

# Download FFmpeg source
cd ffmpeg_sources
git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg

# Configure and compile FFmpeg
cd ffmpeg
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
            --disable-autodetect 

make -j$(sysctl -n hw.ncpu)
make install
