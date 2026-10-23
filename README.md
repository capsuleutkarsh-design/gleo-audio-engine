# Lumen audio engine

This is the sound engine of [Lumen](https://github.com/capsuleutkarsh-design/lumen), a music player for Windows and
Android. It is [mpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org), built for **audio only**, as one file:
`libmpv-2.dll` for Windows x64, and `libmpv.so` for Android (arm64-v8a, armeabi-v7a, x86_64; Android 8 / API 26 and up).
Both are built from the same sources, with the same filters, soxr and bs2b.

Lumen used to ship the general-purpose audio build that comes with `media_kit`. That build is from 2023 and has
almost no audio filters. This one is newer and has what Lumen needs for good sound:

- **Audio filters:** equalizer, bass, treble, lowshelf, highshelf, highpass, lowpass, bandpass, allpass, biquad,
  firequalizer, superequalizer, alimiter, acompressor, crossfeed, bs2b, aresample, volume, loudnorm, ebur128,
  dynaudnorm, extrastereo, stereotools, pan, aformat, anull, asplit, amix, adelay, afir, headphone, aecho,
  amovie (reads an impulse-response WAV for convolution inside the filter chain).
- **Gleo's own additions** (since v2026.10.23; the code is in [`patches/`](patches), LGPL like FFmpeg and mpv):
  - `gleoscope`, an audio filter that copies the newest samples for Gleo's live spectrum. The audio passes through
    untouched, in its own format (a bit-perfect chain stays bit-perfect). libmpv exports `gleo_scope_read()` to read them.
  - Three libswresample options for the soxr resampler: `soxr_phase` (0 minimum, 25 intermediate, 50 linear phase),
    `soxr_stopband` (above 1 allows some aliasing for a gentler filter) and `soxr_steep`. FFmpeg itself only passes
    soxr's precision, cutoff and Chebyshev switch.
  - DoP (DSD over PCM) decoders: `dsd_lsbf_dop`, `dsd_msbf_dop`, `dsd_lsbf_planar_dop`, `dsd_msbf_planar_dop`. They are
    registered after FFmpeg's own DSD decoders, so nothing uses them unless asked by name (mpv `--ad=`). They turn DSD into
    32-bit samples at a sixteenth of the DSD bit rate (DSD64 → 176.4 kHz) with the DoP 0x05/0xFA markers, for DACs that
    accept DoP. Played any other way, DoP is loud noise.
- **libsoxr**, the high-quality resampler (`aresample=resampler=soxr`, or mpv's `--audio-swresample-o=resampler=soxr`).
- **libbs2b**, Bauer stereo-to-binaural crossfeed for headphones (the `bs2b` filter).
- **Local files only.** Every network protocol is switched off; FFmpeg can open `file` only. No scripting
  (Lua, JavaScript, C plugins) and no subtitle font providers.
- **Formats:** FLAC, ALAC, WAV/W64/AIFF/CAF (PCM), MP3, AAC/M4A, Opus, Vorbis, WavPack, APE, TTA, TAK, DSD (DSF/DFF),
  WMA, MPC, AC-3/E-AC-3, DTS, TrueHD, and the usual cover-art images.

It is built in public by the GitHub Actions workflow in this repo, from pinned source versions, so anyone can see and
repeat exactly how the DLL was made.

## Download

Windows releases are named `v<year>.<month>.<day>`, Android releases `v<year>.<month>.<day>-android`.
Each [release](https://github.com/capsuleutkarsh-design/lumen-audio-engine/releases) has:

| File | What it is |
|---|---|
| `lumen-audio-engine-<tag>-win64.zip` | `libmpv-2.dll`, the mpv headers, `LICENSES/`, `BUILDINFO.txt`, `CONFIGURE.txt` |
| `lumen-audio-engine-<tag>.zip` (Android) | `lib/<abi>/libmpv.so` (the APK / jniLibs layout), the mpv headers, `LICENSES/`, `BUILDINFO.txt`, `CONFIGURE.txt` |
| `lumen-audio-engine-<tag>-source.tar` | The complete corresponding source: every source tarball used, exactly as built, plus these build scripts and the licences |
| `SHA256SUMS.txt` | SHA-256 of the zip, the DLL (or each `libmpv.so`) and the source tar |
| `CONFIGURE.txt` | The exact configure command of every part (FFmpeg, mpv and each library) |
| `BUILDINFO.txt` | The versions, download URLs and SHA-256 of all sources and of the compiler |

## What is inside, and the licences

| Part | Version | Licence |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) (built with `--enable-version3`, never `--enable-gpl`) | 8.1.3 | LGPL-3.0-or-later |
| [mpv](https://mpv.io) (built with `-Dgpl=false`) | 0.41.0 | LGPL-2.1-or-later |
| [libplacebo](https://code.videolan.org/videolan/libplacebo) (needed to build mpv) | 7.360.1 | LGPL-2.1-or-later |
| [fast_float](https://github.com/fastfloat/fast_float) (inside libplacebo) | as in libplacebo | MIT / Apache-2.0 / BSL-1.0 |
| [libsoxr](https://sourceforge.net/projects/soxr/) | 0.1.3 | LGPL-2.1-or-later |
| [libbs2b](http://bs2b.sourceforge.net) | 3.1.0 | MIT |
| [libass](https://github.com/libass/libass) (needed to build mpv) | 0.17.5 | ISC |
| [HarfBuzz](https://harfbuzz.github.io) | 14.6.0 | MIT ("Old MIT") |
| [FreeType](https://freetype.org) | 2.14.3 | FreeType License (FTL) |
| [FriBidi](https://github.com/fribidi/fribidi) | 1.0.17 | LGPL-2.1-or-later |
| [zlib](https://zlib.net) | 1.3.2 | zlib |
| [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) runtime (libc++, libunwind, compiler-rt, mingw-w64 CRT), linked in statically | 20260922 | Apache-2.0 WITH LLVM-exception; mingw-w64 runtime licence |

On Android the C++ runtime is the NDK's libc++ (Apache-2.0 WITH LLVM-exception), linked in statically; the
mingw-w64 runtime is Windows only. The Android `libmpv.so` needs only Android system libraries (libc, libm, libdl,
libandroid, libOpenSLES), has mpv's AudioTrack, AAudio and OpenSL ES outputs, and exports `mpv_lavc_set_java_vm`,
which media_kit calls to give FFmpeg the Java VM (the same function as media_kit's own Android builds).

So the whole DLL (and each `libmpv.so`) is under the **LGPL, version 3 or later** (FFmpeg with version3 makes it so), and the other parts keep
their own permissive or LGPL licences. Every licence text is in `LICENSES/` in the zip. There is no GPL-only code and no
non-free code.

What the LGPL asks of anyone who ships this DLL (Lumen does all of this):
1. Say that the program uses these libraries, under these licences, and include the licence texts
   (LGPL-3.0, plus GPL-3.0 because LGPL-3.0 refers to it).
2. Give the corresponding source: link to the release here, whose `-source.tar` has it all.
3. Let users swap the DLL for their own build: it is a normal DLL next to the program.

## Rebuild it yourself

On Ubuntu 24.04 (or in GitHub Actions):

```sh
sudo apt-get install nasm ninja-build pkg-config zip python3-jinja2 cmake git curl xz-utils
pipx install meson==1.9.2
./build.sh            # Windows: about 5 minutes; the result is in out/
sudo apt-get install unzip
./build-android.sh    # Android: about 7 minutes for the three ABIs; the result is in out-android/
```

`common.sh` holds what both share: the pinned sources, the FFmpeg component lists and the licence list.
`build-android.sh` downloads the Android NDK r28c (the version Flutter uses, SHA-256 pinned) and builds for API 26.
It checks that each `libmpv.so` needs only Android system libraries, has no text relocations, is 16 KB page aligned
(Android 15+), exports `mpv_lavc_set_java_vm` and `gleo_scope_read`, has every filter, the DoP decoders and soxr, and is
not a GPL build.

Both scripts apply Gleo's patches (`patch_sources` in `common.sh`) right after unpacking the sources: they copy
`patches/ffmpeg/af_gleoscope.c` into FFmpeg, apply `patches/ffmpeg/*.patch`, and append `patches/mpv/client-gleo.c` to
mpv's `player/client.c`.

`build.sh` downloads the compiler ([llvm-mingw](https://github.com/mstorsjo/llvm-mingw), UCRT) and every source
tarball, checks each SHA-256, builds the libraries statically, then FFmpeg, then `libmpv-2.dll`. At the end it checks that:
the DLL needs only Windows system DLLs, every filter above and the DoP decoders are in it, it exports `gleo_scope_read`,
soxr is in, and it is not a GPL build.

To build on GitHub: **Actions → Build and release → Run workflow**, and pick Windows, Android or both. With "Publish"
ticked, it makes the release `v<today>` (Windows) and/or `v<today>-android`. A release that already exists is never
replaced, because Lumen pins each release's SHA-256: delete it by hand first if you really mean to.

## How an update works

1. Change a version in `common.sh` (the `SOURCES` list or `PLACEBO_COMMIT`) and its SHA-256.
2. Run the workflow. A new release `v<date>` appears.
3. In Lumen, change the release tag and the zip's SHA-256 in `windows/CMakeLists.txt` (Windows) and
   `android/app/build.gradle.kts` (Android).

## Who made it

Built for Lumen by Utkarsh Tripathi. mpv, FFmpeg and the libraries are the work of their authors; this repo only
holds the build script. Thanks to the [media_kit](https://github.com/media-kit/media-kit) project, whose
[libmpv-win32-audio-build](https://github.com/media-kit/libmpv-win32-audio-build) showed the way.
