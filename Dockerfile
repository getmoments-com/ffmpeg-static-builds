# syntax=docker/dockerfile:1
# check=skip=FromPlatformFlagConstDisallowed  -- amd64-only is deliberate, this never multi-platforms

# Static ffmpeg/ffprobe for the video-workers pipeline. The codec set is deliberately narrow:
# only what that pipeline actually invokes, plus NVENC/NVDEC. Note that nothing in the pipeline
# selects h264_nvenc or the CUDA filters yet (FFMPEG.Options.H264() picks libx264, or
# videotoolbox on dev Macs) — they are reserved for a future GPU encode path and are near-free
# to carry: a header-only build dep, and driver libs loaded via dlopen at runtime.
#
#   encode : libx264, libwebp, aac, pcm_s16le/pcm_f32le, mjpeg   (h264_nvenc reserved for GPU)
#   decode : h264, hevc, prores, vp8/vp9, mp3, aac, pcm — all native to ffmpeg — plus dav1d for AV1
#   filter : zscale (libzimg) + tonemap, on essentially every command the pipeline runs
#   bsf    : h264_metadata, appended to every H.264 encode
#   io     : mp4/mov/mkv/hls-fmp4/rawvideo/wav/f32le/image2, concat demuxer, lavfi indev, https
#
# Encoders for formats nothing produces (HEVC/x265, AV1/aom, VP9/vpx, mp3/lame, vorbis, theora,
# speex, AMR, rubberband, vidstab, soxr) are intentionally absent — their *decoders* are native to
# ffmpeg, so ingest of those formats is unaffected. Three things here are load-bearing and must
# not be trimmed: libzimg (zscale), openssl (S3 https reads) and the lavfi indev (anullsrc).

# The ffmpeg release to build. The normal bump flow is: update FFMPEG_VERSION and FFMPEG_SHA256
# (in the build stage below) together, commit, tag. `--build-arg FFMPEG_VERSION=x.y.z` still
# works for ad-hoc builds of other versions; build-ubuntu.sh then blanks the sha check.
ARG FFMPEG_VERSION=8.1.2

FROM --platform=linux/amd64 ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/bin:$PATH"
ENV PKG_CONFIG_PATH="/opt/lib/pkgconfig:/opt/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
ENV LDFLAGS="-L/opt/lib -L/opt/lib/x86_64-linux-gnu"
ENV CFLAGS="-I/opt/include"
ENV CXXFLAGS="-I/opt/include"

# Build dependencies. clang compiles ffmpeg's CUDA filter kernels to PTX (--enable-cuda-llvm) and
# needs no CUDA toolkit. No cmake/yasm/texinfo: every library below uses autotools, meson, or
# OpenSSL's own Configure.
RUN apt-get update && apt-get install -y \
    autoconf \
    automake \
    build-essential \
    clang \
    curl \
    git \
    libtool \
    meson \
    nasm \
    ninja-build \
    pkg-config \
    xz-utils \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Every dependency is pinned AND integrity-checked: git tags are mutable, so tag clones assert
# the tag still points at the recorded commit; plain tarballs are sha256-pinned. Bump a version
# by updating its ARG pair below — layers above the bumped one stay cached, the bumped layer and
# everything after it rebuild (layer cache is linear), which is why the fastest-moving pin
# (ffmpeg itself) sits last.

# libx264 (H.264 encoder) — the pipeline's only video encoder. x264 publishes no release tags, so
# this pins a commit via the GitLab archive endpoint; the commit hash in the URL is what
# content-addresses the download (GitLab archive bytes are not stable across GitLab versions, so
# a tarball sha would be brittle). --disable-cli skips the standalone binary.
ARG X264_COMMIT=0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
RUN curl -Lo x264.tar.gz "https://code.videolan.org/videolan/x264/-/archive/${X264_COMMIT}/x264-${X264_COMMIT}.tar.gz" && \
    tar xzf x264.tar.gz && \
    cd "x264-${X264_COMMIT}" && \
    ./configure --prefix=/opt --enable-static --disable-shared --enable-pic --disable-cli && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf "x264-${X264_COMMIT}" x264.tar.gz

# dav1d (AV1 decoder). Nothing encodes AV1; this is decode-side cover for AV1 sources, which
# ffmpeg's native av1 decoder would handle far more slowly.
ARG DAV1D_VERSION=1.5.4
ARG DAV1D_COMMIT=54706fc6bc0cdecab7e9593974a4039cc038fca7
RUN git clone --depth 1 --branch "${DAV1D_VERSION}" https://code.videolan.org/videolan/dav1d.git && \
    cd dav1d && \
    test "$(git rev-parse HEAD)" = "${DAV1D_COMMIT}" || { echo "dav1d tag ${DAV1D_VERSION} no longer points at ${DAV1D_COMMIT}"; exit 1; } && \
    meson setup build --prefix=/opt --default-library=static --buildtype=release \
        -Denable_tools=false -Denable_tests=false && \
    ninja -C build && \
    ninja -C build install && \
    cd .. && rm -rf dav1d

# libopus. Not selected today (LOSSY_AUDIO_CODEC is aac) but referenced by name as
# AudioCodec.OPUS, so `-c:a libopus` has to keep resolving.
ARG OPUS_VERSION=v1.5.2
ARG OPUS_COMMIT=ddbe48383984d56acd9e1ab6a090c54ca6b735a6
RUN git clone --depth 1 --branch "${OPUS_VERSION}" https://github.com/xiph/opus.git && \
    cd opus && \
    test "$(git rev-parse HEAD)" = "${OPUS_COMMIT}" || { echo "opus tag ${OPUS_VERSION} no longer points at ${OPUS_COMMIT}"; exit 1; } && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared --disable-doc --disable-extra-programs && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf opus

# libwebp — the only WebP encoder ffmpeg has, and thumbnails are WebP (IMAGE_FORMAT).
ARG LIBWEBP_VERSION=v1.6.0
ARG LIBWEBP_COMMIT=4fa21912338357f89e4fd51cf2368325b59e9bd9
RUN git clone --depth 1 --branch "${LIBWEBP_VERSION}" https://chromium.googlesource.com/webm/libwebp && \
    cd libwebp && \
    test "$(git rev-parse HEAD)" = "${LIBWEBP_COMMIT}" || { echo "libwebp tag ${LIBWEBP_VERSION} no longer points at ${LIBWEBP_COMMIT}"; exit 1; } && \
    autoreconf -fiv && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf libwebp

# zimg — backs the zscale filter, which every tonemapping/colour-normalising command depends on.
ARG ZIMG_VERSION=release-3.0.6
ARG ZIMG_COMMIT=f819b14e8f39d1282400b0d9543e8ef73c1b2bbd
RUN git clone --depth 1 --branch "${ZIMG_VERSION}" --recursive https://github.com/sekrit-twc/zimg.git && \
    cd zimg && \
    test "$(git rev-parse HEAD)" = "${ZIMG_COMMIT}" || { echo "zimg tag ${ZIMG_VERSION} no longer points at ${ZIMG_COMMIT}"; exit 1; } && \
    ./autogen.sh && \
    ./configure --prefix=/opt --enable-static --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf zimg

# OpenSSL, for the TLS/HTTPS reads of S3 presigned URLs.
# --openssldir=/etc/ssl is deliberate: OpenSSL bakes that path in as its CA store, and /etc/ssl is
# where the runtime image's ca-certificates package puts the bundle. The old /opt/ssl does not
# exist at runtime, which is harmless only while ffmpeg still defaults tls_verify=0 (ffmpeg 8.x /
# libavformat 62) and would break every https read the moment that default flips in ffmpeg 9.
# (Ubuntu's libssl-dev would also work and skip this build, at the cost of pinning our own version.)
# The sha256 comes from upstream's published openssl-<version>.tar.gz.sha256 release asset.
ARG OPENSSL_VERSION=3.5.7
ARG OPENSSL_SHA256=a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
RUN curl -LO "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" && \
    echo "${OPENSSL_SHA256}  openssl-${OPENSSL_VERSION}.tar.gz" | sha256sum -c && \
    tar xzf "openssl-${OPENSSL_VERSION}.tar.gz" && \
    cd "openssl-${OPENSSL_VERSION}" && \
    ./Configure --prefix=/opt --openssldir=/etc/ssl no-shared no-docs linux-x86_64 && \
    make -j$(nproc) && \
    make install_sw && \
    cd .. && rm -rf "openssl-${OPENSSL_VERSION}" "openssl-${OPENSSL_VERSION}.tar.gz"

# NVENC/NVDEC headers (ffnvcodec) — header-only, no CUDA toolkit needed. ffmpeg dlopen()s the
# driver's libnvidia-encode/libnvcuvid at runtime, so the build machine needs no GPU either.
# n12.2.72.0 requires driver >= 550.54 at runtime (cluster runs 575.x).
ARG NV_CODEC_HEADERS_VERSION=n12.2.72.0
ARG NV_CODEC_HEADERS_COMMIT=c69278340ab1d5559c7d7bf0edf615dc33ddbba7
RUN git clone --depth 1 --branch "${NV_CODEC_HEADERS_VERSION}" https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && \
    test "$(git rev-parse HEAD)" = "${NV_CODEC_HEADERS_COMMIT}" || { echo "nv-codec-headers tag ${NV_CODEC_HEADERS_VERSION} no longer points at ${NV_CODEC_HEADERS_COMMIT}"; exit 1; } && \
    make install PREFIX=/opt && \
    cd .. && rm -rf nv-codec-headers

# Download and extract FFmpeg source. FFMPEG_SHA256 pins the tarball for the default version
# above; pass FFMPEG_SHA256="" (build-ubuntu.sh does this automatically for non-default versions)
# to skip the check, loudly.
ARG FFMPEG_VERSION
ARG FFMPEG_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
RUN curl -LO https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    if [ -n "${FFMPEG_SHA256}" ]; then \
        echo "${FFMPEG_SHA256}  ffmpeg-${FFMPEG_VERSION}.tar.xz" | sha256sum -c; \
    else \
        echo "WARNING: FFMPEG_SHA256 is empty - skipping ffmpeg tarball integrity check"; \
    fi && \
    tar -xf ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    rm ffmpeg-${FFMPEG_VERSION}.tar.xz

WORKDIR /build/ffmpeg-${FFMPEG_VERSION}

# Configure and build FFmpeg.
RUN PKG_CONFIG_PATH="/opt/lib/pkgconfig:/opt/lib/x86_64-linux-gnu/pkgconfig:/opt/lib64/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig" \
    ./configure \
    --prefix=/opt \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-doc \
    # Capture/playback sinks are useless here. Input devices stay enabled: `-f lavfi -i anullsrc`
    # is the lavfi *indev*, and the pipeline relies on it wherever a source has no audio track.
    --disable-outdevs \
    --enable-gpl \
    # version3 is no longer required by any enabled library, but it is the license-coherent
    # choice: GPL + Apache-2.0 OpenSSL is compatible under GPLv3, not GPLv2. Note there is no
    # --enable-nonfree — none of the nonfree libraries (fdk-aac, decklink, mpeghdec) are used,
    # and a nonfree-flagged binary could not be published as a GitHub Release at all.
    --enable-version3 \
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
    # CUDA filters (scale_cuda, overlay_cuda, ...) so a future GPU path does not have to
    # round-trip through host memory for every scale. Compiled by clang, not nvcc. cuda_llvm is
    # an autodetected component, so this explicit enable makes configure *die* if clang cannot
    # compile the kernels; the verify stage asserts scale_cuda anyway, guarding against the flag
    # itself being dropped (autodetect would then silently decide).
    --enable-cuda-llvm \
    --enable-openssl \
    --enable-libx264 \
    --enable-libzimg \
    --enable-libwebp \
    --enable-libdav1d \
    --enable-libopus

RUN make -j$(nproc)

# Create the distributable package
RUN mkdir -p /output/ffmpeg-${FFMPEG_VERSION}-amd64-static && \
    cp ffmpeg ffprobe /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ && \
    strip /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffmpeg && \
    strip /output/ffmpeg-${FFMPEG_VERSION}-amd64-static/ffprobe && \
    cd /output && \
    tar -cJf ffmpeg-release-amd64-static.tar.xz ffmpeg-${FFMPEG_VERSION}-amd64-static

# Verification runs on a bare ubuntu:24.04 — the same image video-workers runs on — so a stray
# dynamic dependency or a silently dropped feature fails this image build rather than a
# production job. (An earlier build picked up libgomp.so.1, which the runtime image lacks; no
# check inside the toolchain-rich build stage can catch that class of bug.) h264_nvenc and the
# cuda hwaccel register without a GPU present (driver libs load lazily on use), so everything
# here passes on GPU-less machines.
FROM --platform=linux/amd64 ubuntu:24.04 AS verify
ARG FFMPEG_VERSION
COPY --from=build /output /output
RUN <<'VERIFY'
#!/bin/bash
set -euo pipefail
OUT="/output/ffmpeg-${FFMPEG_VERSION}-amd64-static"

"$OUT/ffmpeg" -version
"$OUT/ffprobe" -version > /dev/null

# Registration checks, matched against the exact component name (column 2 of flagged listings,
# column 1 of plain ones) — not against description text. grep reads to EOF (no -q): under
# pipefail, -q's early exit can SIGPIPE the writer and fake a failure.
need2() { list=$1; shift; for n in "$@"; do "$OUT/ffmpeg" -hide_banner "-$list" | awk '{print $2}' | grep -x -- "$n" > /dev/null || { echo "MISSING ${list%s}: $n"; exit 1; }; done; }
need1() { list=$1; shift; for n in "$@"; do "$OUT/ffmpeg" -hide_banner "-$list" | awk '{print $1}' | grep -x -- "$n" > /dev/null || { echo "MISSING ${list%s}: $n"; exit 1; }; done; }

need2 encoders  libx264 libwebp libopus aac pcm_s16le pcm_f32le mjpeg h264_nvenc
need2 decoders  h264 hevc prores vp8 vp9 mp3 aac png webp libdav1d
need2 filters   zscale tonemap loudnorm gblur zoompan vstack xstack overlay tpad scale_cuda
need2 muxers    mp4 mov matroska hls webp image2 rawvideo wav f32le
need2 demuxers  concat hls wav mov,mp4,m4a,3gp,3g2,mj2 matroska,webm
need2 devices   lavfi
need1 bsfs      h264_metadata
need1 protocols https pipe
need1 hwaccels  cuda

# Functional smoke tests: registration proves linkage, not operation. These run the exact command
# shapes the pipeline builds (both filter_tonemapping branches, the h264_metadata bsf, lavfi
# silent audio, concat demuxer, HLS fMP4, WebP stills, ffprobe JSON) in a couple of seconds.
cd "$(mktemp -d)"

"$OUT/ffmpeg" -v error \
    -f lavfi -i testsrc2=duration=1:size=640x360:rate=25 \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
    -vf 'zscale=rin=limited:min=bt709:pin=bt709:tin=bt709:p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p' \
    -af loudnorm \
    -c:v libx264 -preset ultrafast \
    -bsf:v h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0 \
    -c:a aac -shortest -movflags faststart -y sdr.mp4

# testsrc2 emits RGB-tagged SDR frames; format+setparams first turn them into what real HDR
# ingest looks like (10-bit, bt2020/PQ-tagged), which is what the zscale chain expects.
"$OUT/ffmpeg" -v error -f lavfi -i testsrc2=duration=0.2:size=320x180:rate=25 \
    -vf 'format=yuv420p10le,setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084,zscale=tin=smpte2084:min=bt2020nc:pin=bt2020:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p' \
    -c:v libx264 -preset ultrafast -y hdr.mp4

"$OUT/ffprobe" -v error -print_format json -show_format -show_streams sdr.mp4 > /dev/null

"$OUT/ffmpeg" -v error -i sdr.mp4 -frames:v 1 -c:v libwebp -y thumb.webp

printf "file '%s'\nfile '%s'\n" "$PWD/sdr.mp4" "$PWD/sdr.mp4" > list.txt
"$OUT/ffmpeg" -v error -f concat -safe 0 -i list.txt -c copy -y joined.mp4

mkdir hls
"$OUT/ffmpeg" -v error -i sdr.mp4 -c copy -f hls -hls_time 1 -hls_segment_type fmp4 \
    -master_pl_name master.m3u8 hls/stream.m3u8

# The runtime contract is "runs on bare ubuntu:24.04": glibc family, libstdc++ (zimg is C++),
# libgcc_s and libz only. Anything else must fail the build, not the first production job.
for bin in ffmpeg ffprobe; do
    bad=$(ldd "$OUT/$bin" | awk '{print $1}' | grep -vE '^(linux-vdso|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libstdc\+\+\.so|libgcc_s\.so|libz\.so|/lib64/ld-linux-x86-64)' || true)
    if [ -n "$bad" ]; then echo "UNEXPECTED DYNAMIC DEPS in $bin: $bad"; exit 1; fi
done

ldd "$OUT/ffmpeg"
ls -l "$OUT"
echo "Build verified."
VERIFY

# Extraction target for build-ubuntu.sh (`--target artifact --output type=local,dest=output`).
# Copying from `verify` rather than `build` forces the verify stage to run even when only this
# stage is targeted.
FROM scratch AS artifact
COPY --from=verify /output/ffmpeg-release-amd64-static.tar.xz /
