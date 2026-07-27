#!/bin/bash
#
# Build the static (NVENC-enabled) ffmpeg/ffprobe package for Ubuntu amd64.
#
# Usage:
#   ./build-ubuntu.sh            # build the Dockerfile's default FFMPEG_VERSION
#   ./build-ubuntu.sh 8.1.2      # build a specific ffmpeg release
#
# Extra `docker buildx build` args can be passed via EXTRA_BUILD_ARGS (CI uses this for
# --cache-from/--cache-to). The Dockerfile's verify stage runs as part of the build; the
# package only lands in output/ if every check passed.
set -euo pipefail

# Version comes from $1, else the FFMPEG_VERSION env var, else the Dockerfile ARG default.
FFMPEG_VERSION="${1:-${FFMPEG_VERSION:-}}"

echo "Building static FFmpeg for Ubuntu amd64${FFMPEG_VERSION:+ (version ${FFMPEG_VERSION})}..."

BUILD_ARGS=()
if [ -n "$FFMPEG_VERSION" ]; then
    BUILD_ARGS+=(--build-arg "FFMPEG_VERSION=${FFMPEG_VERSION}")
    # The Dockerfile pins the sha256 of its default version's tarball. For any other version
    # there is no recorded hash, so blank the check (loudly) instead of failing on a stale pin.
    DEFAULT_VERSION=$(sed -n 's/^ARG FFMPEG_VERSION=//p' Dockerfile | head -1)
    if [ "$FFMPEG_VERSION" != "$DEFAULT_VERSION" ]; then
        echo "WARNING: no pinned sha256 for ffmpeg ${FFMPEG_VERSION} (Dockerfile pins ${DEFAULT_VERSION});" \
             "the tarball integrity check is skipped. Prefer bumping FFMPEG_VERSION+FFMPEG_SHA256 in the Dockerfile."
        BUILD_ARGS+=(--build-arg "FFMPEG_SHA256=")
    fi
fi

# Build (native on amd64 runners; no QEMU) and export the artifact stage straight to output/.
# Targeting `artifact` still runs the verify stage — artifact copies the package from it.
mkdir -p output
docker buildx build --platform linux/amd64 "${BUILD_ARGS[@]}" ${EXTRA_BUILD_ARGS:-} \
    --target artifact --output "type=local,dest=output" .

echo ""
echo "Build complete! Package is ready:"
ls -la output/ffmpeg-release-amd64-static.tar.xz

echo ""
echo "Package contents:"
tar -tvf output/ffmpeg-release-amd64-static.tar.xz
