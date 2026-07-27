FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/bin:$PATH"
ENV PKG_CONFIG_PATH="/opt/lib/pkgconfig:/opt/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
ENV LDFLAGS="-L/opt/lib -L/opt/lib/x86_64-linux-gnu"
ENV CFLAGS="-I/opt/include"
ENV CXXFLAGS="-I/opt/include"

# Install build dependencies
RUN apt-get update && apt-get install -y \
    autoconf \
    automake \
    build-essential \
    cmake \
    curl \
    git \
    libtool \
    meson \
    nasm \
    ninja-build \
    pkg-config \
    texinfo \
    wget \
    xz-utils \
    yasm \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build libx264 (H.264 encoder)
RUN git clone --depth 1 https://code.videolan.org/videolan/x264.git && \
    cd x264 && \
    ./configure --prefix=/opt --enable-static --disable-shared --enable-pic && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf x264

# Build libx265 (H.265/HEVC encoder)
RUN git clone --depth 1 https://bitbucket.org/multicoreware/x265_git.git && \
    cd x265_git/build/linux && \
    cmake -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX=/opt \
        -DLIB_INSTALL_DIR=/opt/lib \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        ../../source && \
    make -j$(nproc) && \
    make install && \
    # Create pkg-config file manually (x265 doesn't generate one for static builds)
    mkdir -p /opt/lib/pkgconfig && \
    echo 'prefix=/opt' > /opt/lib/pkgconfig/x265.pc && \
    echo 'exec_prefix=${prefix}' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'libdir=${prefix}/lib' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'includedir=${prefix}/include' >> /opt/lib/pkgconfig/x265.pc && \
    echo '' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Name: x265' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Description: H.265/HEVC video encoder' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Version: 3.5' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Libs: -L${libdir} -lx265' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Libs.private: -lstdc++ -lm -lpthread' >> /opt/lib/pkgconfig/x265.pc && \
    echo 'Cflags: -I${includedir}' >> /opt/lib/pkgconfig/x265.pc && \
    cd /build && rm -rf x265_git

# Build libvpx (VP8/VP9)
RUN git clone --depth 1 https://chromium.googlesource.com/webm/libvpx.git && \
    cd libvpx && \
    ./configure --prefix=/opt --disable-examples --disable-unit-tests \
        --enable-vp9-highbitdepth --as=yasm --enable-pic --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf libvpx

# Build libaom (AV1)
RUN git clone --depth 1 https://aomedia.googlesource.com/aom && \
    mkdir aom_build && cd aom_build && \
    cmake -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX=/opt \
        -DENABLE_SHARED=OFF \
        -DENABLE_NASM=ON \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_DOCS=OFF \
        ../aom && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf aom aom_build

# Build dav1d (AV1 decoder - faster than libaom for decoding)
RUN git clone --depth 1 https://code.videolan.org/videolan/dav1d.git && \
    cd dav1d && \
    meson setup build --prefix=/opt --default-library=static --buildtype=release && \
    ninja -C build && \
    ninja -C build install && \
    cd .. && rm -rf dav1d

# Build libmp3lame (MP3 encoder)
RUN curl -LO https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz && \
    tar xzf lame-3.100.tar.gz && \
    cd lame-3.100 && \
    ./configure --prefix=/opt --enable-static --disable-shared --enable-nasm && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf lame-3.100 lame-3.100.tar.gz

# Build libopus
RUN git clone --depth 1 https://github.com/xiph/opus.git && \
    cd opus && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf opus

# Build libvorbis (requires libogg)
RUN git clone --depth 1 https://github.com/xiph/ogg.git && \
    cd ogg && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf ogg

RUN git clone --depth 1 https://github.com/xiph/vorbis.git && \
    cd vorbis && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf vorbis

# Build libtheora
RUN git clone --depth 1 https://github.com/xiph/theora.git && \
    cd theora && \
    ./autogen.sh && \
    ./configure --prefix=/opt --enable-static --disable-shared --disable-examples && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf theora

# Build libwebp
RUN git clone --depth 1 https://chromium.googlesource.com/webm/libwebp && \
    cd libwebp && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf libwebp

# Build libsoxr (resampler)
RUN git clone --depth 1 https://git.code.sf.net/p/soxr/code soxr && \
    cd soxr && \
    mkdir build && cd build && \
    cmake -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX=/opt \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_OPENMP=OFF \
        -DBUILD_TESTS=OFF \
        .. && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf soxr

# Build zimg
RUN git clone --depth 1 --recursive https://github.com/sekrit-twc/zimg.git && \
    cd zimg && \
    ./autogen.sh && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf zimg

# Build vidstab. USE_OMP=OFF: libgomp.so.1 is not in the bare ubuntu:24.04 runtime image, and
# the now-dynamic binary must only need libs that ship with the base (glibc, libstdc++, libz).
RUN git clone --depth 1 https://github.com/georgmartius/vid.stab.git && \
    cd vid.stab && \
    mkdir build && cd build && \
    cmake -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX=/opt \
        -DBUILD_SHARED_LIBS=OFF \
        -DUSE_OMP=OFF \
        .. && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf vid.stab

# Build opencore-amr
RUN curl -LO https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz && \
    tar xzf opencore-amr-0.1.6.tar.gz && \
    cd opencore-amr-0.1.6 && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf opencore-amr-0.1.6 opencore-amr-0.1.6.tar.gz

# Build vo-amrwbenc
RUN curl -LO https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz && \
    tar xzf vo-amrwbenc-0.1.3.tar.gz && \
    cd vo-amrwbenc-0.1.3 && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf vo-amrwbenc-0.1.3 vo-amrwbenc-0.1.3.tar.gz

# Build speex
RUN git clone --depth 1 https://github.com/xiph/speex.git && \
    cd speex && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf speex

# Build rubberband
RUN git clone --depth 1 https://github.com/breakfastquay/rubberband.git && \
    cd rubberband && \
    meson setup build --prefix=/opt --default-library=static -Dfft=builtin -Dresampler=builtin && \
    ninja -C build && \
    ninja -C build install && \
    cd .. && rm -rf rubberband

# Build OpenSSL (for TLS/HTTPS support)
RUN curl -LO https://www.openssl.org/source/openssl-3.2.1.tar.gz && \
    tar xzf openssl-3.2.1.tar.gz && \
    cd openssl-3.2.1 && \
    ./Configure --prefix=/opt --openssldir=/opt/ssl no-shared linux-x86_64 && \
    make -j$(nproc) && \
    make install_sw && \
    cd .. && rm -rf openssl-3.2.1 openssl-3.2.1.tar.gz

# NVENC/NVDEC headers (ffnvcodec) — header-only, no CUDA toolkit needed. ffmpeg dlopen()s the
# driver's libnvidia-encode/libnvcuvid at runtime, so the build machine needs no GPU either.
# n12.2.72.0 requires driver >= 550.54 at runtime (cluster runs 575.x).
RUN git clone --depth 1 --branch n12.2.72.0 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && \
    make install PREFIX=/opt && \
    cd .. && rm -rf nv-codec-headers

# Download and extract FFmpeg source. Bump FFMPEG_VERSION to build a different release
# (`docker build --build-arg FFMPEG_VERSION=x.y.z`); nv-codec-headers stays pinned above.
ARG FFMPEG_VERSION=8.1.2
RUN curl -LO https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    tar -xf ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    rm ffmpeg-${FFMPEG_VERSION}.tar.xz

WORKDIR /build/ffmpeg-${FFMPEG_VERSION}

# Configure and build FFmpeg with all libraries
RUN PKG_CONFIG_PATH="/opt/lib/pkgconfig:/opt/lib/x86_64-linux-gnu/pkgconfig:/opt/lib64/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig" \
    ./configure \
    --prefix=/opt \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-doc \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --extra-cflags="-I/opt/include" \
    # No -static: NVENC/NVDEC load the driver libs via dlopen, which a fully-static glibc
    # binary cannot do. Third-party libs stay static (pkg-config --static); the binary only
    # links glibc, which matches the ubuntu:24.04 runtime image.
    --extra-ldflags="-L/opt/lib" \
    --extra-libs="-lpthread -lm" \
    --pkg-config-flags="--static" \
    --enable-ffnvcodec \
    --enable-nvenc \
    --enable-nvdec \
    --enable-cuvid \
    --enable-openssl \
    --enable-libdav1d \
    --enable-libmp3lame \
    --enable-libopencore-amrnb \
    --enable-libopencore-amrwb \
    --enable-libopus \
    --enable-librubberband \
    --enable-libsoxr \
    --enable-libspeex \
    --enable-libtheora \
    --enable-libvidstab \
    --enable-libvo-amrwbenc \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libaom \
    --enable-libzimg

RUN make -j$(nproc)

# Create the distributable package
RUN mkdir -p /output/ffmpeg-${FFMPEG_VERSION}-amd64-static && \
    cp ffmpeg ffprobe /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ && \
    strip /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg && \
    strip /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffprobe && \
    cd /output && \
    tar -cJf ffmpeg-release-amd64-static.tar.xz ffmpeg-${FFMPEG_VERSION}-amd64-static

# Verify the build. h264_nvenc registers without a GPU present (driver libs load lazily on
# use), so this also passes on the GPU-less build machine.
RUN /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg -version && \
    /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg -encoders | grep -E "libx264|libx265|libvpx|libaom|libmp3lame" && \
    /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg -encoders | grep h264_nvenc && \
    /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg -hwaccels | grep cuda && \
    ldd /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg && \
    echo "Build successful with all encoders!"
