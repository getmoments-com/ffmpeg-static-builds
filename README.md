# FFmpeg Static Builds

Self-built static `ffmpeg`/`ffprobe` for Ubuntu **amd64**, with **NVENC/NVDEC** hardware
encode/decode enabled. Published as GitHub Releases; consumers pull the release asset directly
(e.g. the video-workers Dockerfile).

The codec set is scoped to what the video-workers pipeline actually invokes rather than to
"everything ffmpeg can link" — see [What's in the build](#whats-in-the-build).

## Latest

Grab the newest build from the
[Releases page](https://github.com/getmoments-com/ffmpeg-static-builds/releases).

Every release ships the same asset name — `ffmpeg-release-amd64-static.tar.xz` — containing a
top-level `ffmpeg-<version>-amd64-static/` directory with `ffmpeg` and `ffprobe`, plus a
`.sha256` companion asset. Consumers should pin that hash next to the download URL (as the
video-workers Dockerfile does): GitHub release assets can be silently re-uploaded, and the
pinned hash is what makes the pull tamper-evident.

## What's in the build

| | |
|---|---|
| **Encode** | `libx264`, `libwebp`, native `aac` / `pcm_s16le` / `mjpeg`, `h264_nvenc` |
| **Decode** | native `h264`, `hevc`, `prores`, `vp8`/`vp9`, `mp3`, `aac`, `pcm`, plus `libdav1d` for AV1 |
| **Filters** | `libzimg` (`zscale`) + native `tonemap`, and the CUDA filter family (`scale_cuda`, …) |
| **I/O** | mp4/mov/mkv/HLS-fMP4/rawvideo/wav/f32le/image2, concat demuxer, lavfi indev, `https` via OpenSSL |

NVENC/NVDEC and the CUDA filters are compiled in and verified, but nothing in the pipeline
selects them yet — `FFMPEG.Options.H264()` picks libx264 (or videotoolbox on dev Macs), and no
code path passes `-hwaccel`. They are reserved for a future GPU encode path and are near-free to
carry: a header-only build dependency, with the driver libraries loaded via dlopen at runtime.

Deliberately **not** linked: x265, aom, vpx, lame, vorbis/ogg, theora, speex, opencore-amr,
vo-amrwbenc, rubberband, vidstab, soxr. Nothing in the pipeline *encodes* any of those formats,
and ffmpeg's **native decoders** cover all of them — so ingest of HEVC (the iPhone default), WebM,
mp3, AMR and friends is unaffected. For reference, the last build that linked them all was 121 MB
of binaries / a 34.7 MB asset; aom, x265 and vpx accounted for most of the difference, and aom and
x265 also dominated compile time.

Three pieces are load-bearing and must survive any future trimming:

- **`libzimg`** — `zscale` appears in nearly every command the pipeline builds, via
  `FFMPEG.Options.filter_tonemapping`.
- **`openssl`** — every S3 presigned-URL read is `https`.
- **the lavfi indev** — `-f lavfi -i anullsrc` is how sources without an audio track get one.
  `--disable-indevs` would break it; only `--disable-outdevs` is safe.

Whitelisting decoders/demuxers is likewise off the table: ingest is arbitrary user-uploaded video.

## How it's built

`Dockerfile` compiles ffmpeg and the libraries above from source on `ubuntu:24.04`, plus
`nv-codec-headers` for NVENC/NVDEC.

Deliberate choices:

- **Not fully static.** Third-party libs are linked statically (`--pkg-config-flags=--static`),
  but the binary links glibc dynamically — a fully-static glibc binary cannot `dlopen` the
  NVIDIA driver's `libnvidia-encode.so` / `libnvcuvid.so`, which NVENC/NVDEC require at runtime.
  Build and runtime are both `ubuntu:24.04`, so the glibc dependency is satisfied. The binary
  runs on a plain `ubuntu:24.04` image with **no GPU** (CPU codecs work; NVENC needs the driver).
- **`nv-codec-headers` is pinned to `n12.2.72.0`** — the lowest NVIDIA driver floor (>= 550.54)
  that still satisfies current ffmpeg, so it runs on older drivers than newer header releases
  would require.
- **Every dependency is pinned and integrity-checked.** Tag-cloned libraries assert the tag
  still points at a recorded commit (git tags are mutable); the OpenSSL and ffmpeg tarballs are
  sha256-pinned; x264 is pinned by commit in a content-addressed archive URL. Two builds of the
  same tag therefore compile the same *sources* — not bit-identical binaries, since the
  toolchain comes from `ubuntu:24.04` apt at build time.
- **GPLv3, not nonfree.** `--enable-gpl --enable-version3` with no `--enable-nonfree`: none of the
  nonfree libraries (fdk-aac, decklink, mpeghdec) are used, and a nonfree-flagged binary may not be
  redistributed at all — which would rule out publishing it as a release asset. `version3` is kept
  because GPL + Apache-2.0 OpenSSL is compatible under GPLv3 but not GPLv2.
- **OpenSSL uses `--openssldir=/etc/ssl`**, matching where the runtime image's `ca-certificates`
  puts the CA bundle. ffmpeg 8.x still defaults `tls_verify=0`, so a wrong path is invisible today
  and would break every `https` read when that default flips in ffmpeg 9.
- **CUDA filters are enabled via `--enable-cuda-llvm`** (clang compiles the kernels; no CUDA
  toolkit needed), so a future GPU path can scale on-device instead of round-tripping through host
  memory. `cuda_llvm` is an autodetected component, so the explicit enable makes configure *die*
  if clang can't compile the kernels; the verify stage asserts `scale_cuda` anyway, in case the
  flag itself is ever dropped.
- **Verification runs on a bare `ubuntu:24.04` stage** — the same image video-workers runs on —
  not inside the toolchain-rich build stage (an earlier build silently picked up `libgomp.so.1`,
  which the runtime image lacks; only a bare-image check catches that class of bug). It asserts
  every encoder, decoder, filter, bitstream filter, muxer, demuxer, protocol and device the
  pipeline invokes; runs functional smoke tests (both `filter_tonemapping` branches, the
  `h264_metadata` bsf, lavfi silent audio, the concat demuxer, HLS fMP4, WebP stills, ffprobe
  JSON); and fails on any dynamic dependency outside the glibc/libstdc++/zlib allowlist. A
  dropped library fails the image build rather than a production job.

## Cutting a release

CI (`.github/workflows/release.yml`) builds and publishes automatically on a version tag:

```
git tag v8.1.2
git push origin v8.1.2
```

The tag drives the ffmpeg version (`v8.1.2` → 8.1.2); a suffix is allowed for rebuilding the same
version with a Dockerfile change (`v8.1.2-nvenc2` → still ffmpeg 8.1.2). The workflow builds on a
native amd64 runner (dependency layers stay warm in the GitHub Actions cache between builds) and
attaches `ffmpeg-release-amd64-static.tar.xz` plus its `.sha256` to the release.

The normal version-bump flow is: update `FFMPEG_VERSION` and `FFMPEG_SHA256` in the Dockerfile
together, commit, tag. Tagging a version that differs from the Dockerfile default still builds —
`build-ubuntu.sh` blanks the tarball hash check with a warning — but the pinned path is
preferred. After a release, update the consumer's pinned URL **and** hash (video-workers
Dockerfile) together.

To build a different version without editing the Dockerfile default, use the **Run workflow**
button (`workflow_dispatch`) with a version input — that produces a downloadable build artifact
without creating a release.

## Building locally

Requires Docker.

```
./build-ubuntu.sh 8.1.2     # or omit the arg to build the Dockerfile default
```

The package lands in `output/ffmpeg-release-amd64-static.tar.xz`.
