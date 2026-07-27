#!/bin/bash
#
# Build the static (NVENC-enabled) ffmpeg/ffprobe package for Ubuntu amd64.
#
# Usage:
#   ./build-ubuntu.sh            # build the Dockerfile's default FFMPEG_VERSION
#   ./build-ubuntu.sh 8.1.2      # build a specific ffmpeg release
#
set -eo pipefail

# Version comes from $1, else the FFMPEG_VERSION env var, else the Dockerfile ARG default.
FFMPEG_VERSION="${1:-${FFMPEG_VERSION:-}}"

echo "Building static FFmpeg for Ubuntu amd64${FFMPEG_VERSION:+ (version ${FFMPEG_VERSION})}..."

BUILD_ARGS=()
if [ -n "$FFMPEG_VERSION" ]; then
    BUILD_ARGS+=(--build-arg "FFMPEG_VERSION=${FFMPEG_VERSION}")
fi

# Build the Docker image (native on amd64 runners; no QEMU).
docker build --platform linux/amd64 "${BUILD_ARGS[@]}" -t ffmpeg-static-ubuntu .

# Extract the package the Dockerfile produced at /output.
mkdir -p output
docker rm -f ffmpeg-extract >/dev/null 2>&1 || true
docker create --name ffmpeg-extract ffmpeg-static-ubuntu
docker cp ffmpeg-extract:/output/ffmpeg-release-amd64-static.tar.xz output/
docker rm ffmpeg-extract

echo ""
echo "Build complete! Package is ready:"
ls -la output/ffmpeg-release-amd64-static.tar.xz

echo ""
echo "Package contents:"
tar -tvf output/ffmpeg-release-amd64-static.tar.xz
