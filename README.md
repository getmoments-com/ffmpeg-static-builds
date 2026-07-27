# FFmpeg Static Builds

Self-built static `ffmpeg`/`ffprobe` for Ubuntu **amd64**, with **NVENC/NVDEC** hardware
encode/decode enabled. Published as GitHub Releases; consumers pull the release asset directly
(e.g. the video-workers Dockerfile).

## Latest

FFmpeg version | Link
---|---
8.1.2 | [link](https://github.com/getmoments-com/ffmpeg-static-builds/releases/download/v8.1.2/ffmpeg-release-amd64-static.tar.xz)

Every release ships the same asset name — `ffmpeg-release-amd64-static.tar.xz` — containing a
top-level `ffmpeg-<version>-amd64-static/` directory with `ffmpeg` and `ffprobe`.

## How it's built

`Dockerfile` compiles ffmpeg and its codec libraries (x264, x265, aom, dav1d, vpx, opus, …) from
source on `ubuntu:24.04`, plus `nv-codec-headers` for NVENC/NVDEC.

Two deliberate choices:

- **Not fully static.** Third-party libs are linked statically (`--pkg-config-flags=--static`),
  but the binary links glibc dynamically — a fully-static glibc binary cannot `dlopen` the
  NVIDIA driver's `libnvidia-encode.so` / `libnvcuvid.so`, which NVENC/NVDEC require at runtime.
  Build and runtime are both `ubuntu:24.04`, so the glibc dependency is satisfied. The binary
  runs on a plain `ubuntu:24.04` image with **no GPU** (CPU codecs work; NVENC needs the driver).
- **`nv-codec-headers` is pinned to `n12.2.72.0`** — the lowest NVIDIA driver floor (>= 550.54)
  that still satisfies current ffmpeg, so it runs on older drivers than newer header releases
  would require.

## Cutting a release

CI (`.github/workflows/release.yml`) builds and publishes automatically on a version tag:

```
git tag v8.1.2
git push origin v8.1.2
```

The tag drives the ffmpeg version (`v8.1.2` → 8.1.2); a suffix is allowed for rebuilding the same
version with a Dockerfile change (`v8.1.2-nvenc2` → still ffmpeg 8.1.2). The workflow builds on a
native amd64 runner and attaches `ffmpeg-release-amd64-static.tar.xz` to the release.

To build a different version without editing the Dockerfile default, use the **Run workflow**
button (`workflow_dispatch`) with a version input — that produces a downloadable build artifact
without creating a release.

## Building locally

Requires Docker.

```
./build-ubuntu.sh 8.1.2     # or omit the arg to build the Dockerfile default
```

The package lands in `output/ffmpeg-release-amd64-static.tar.xz`.
