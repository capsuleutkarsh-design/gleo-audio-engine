# Lumen audio engine

This is the sound engine of [Lumen](https://github.com/capsuleutkarsh-design/lumen), a music player for Windows.
It is one file, `libmpv-2.dll`: [mpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org), built for **audio only**,
for Windows x64.

Lumen used to ship the general-purpose audio build that comes with `media_kit`. That build is from 2023 and has
almost no audio filters. This one is newer and has what Lumen needs for good sound:

- **Audio filters:** equalizer, bass, treble, lowshelf, highshelf, highpass, lowpass, bandpass, allpass, biquad,
  firequalizer, superequalizer, alimiter, acompressor, crossfeed, bs2b, aresample, volume, loudnorm, ebur128,
  dynaudnorm, extrastereo, stereotools, pan, aformat, anull, asplit, amix, adelay, afir, headphone, aecho.
- **libsoxr**, the high-quality resampler (`aresample=resampler=soxr`, or mpv's `--audio-swresample-o=resampler=soxr`).
- **libbs2b**, Bauer stereo-to-binaural crossfeed for headphones (the `bs2b` filter).
- **Local files only.** Every network protocol is switched off; FFmpeg can open `file` only. No scripting
  (Lua, JavaScript, C plugins) and no subtitle font providers.
- **Formats:** FLAC, ALAC, WAV/W64/AIFF/CAF (PCM), MP3, AAC/M4A, Opus, Vorbis, WavPack, APE, TTA, TAK, DSD (DSF/DFF),
  WMA, MPC, AC-3/E-AC-3, DTS, TrueHD, and the usual cover-art images.

It is built in public by the GitHub Actions workflow in this repo, from pinned source versions, so anyone can see and
repeat exactly how the DLL was made.

## Download

Each [release](https://github.com/capsuleutkarsh-design/lumen-audio-engine/releases) (named `v<year>.<month>.<day>`) has:

| File | What it is |
|---|---|
| `lumen-audio-engine-<tag>-win64.zip` | `libmpv-2.dll`, the mpv headers, `LICENSES/`, `BUILDINFO.txt`, `CONFIGURE.txt` |
| `lumen-audio-engine-<tag>-source.tar` | The complete corresponding source: every source tarball used, exactly as built, plus these build scripts and the licences |
| `SHA256SUMS.txt` | SHA-256 of the zip, the DLL and the source tar |
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

So the whole DLL is under the **LGPL, version 3 or later** (FFmpeg with version3 makes it so), and the other parts keep
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
./build.sh            # about 15 minutes; the result is in out/
```

`build.sh` downloads the compiler ([llvm-mingw](https://github.com/mstorsjo/llvm-mingw), UCRT) and every source
tarball, checks each SHA-256, builds the libraries statically, then FFmpeg, then `libmpv-2.dll`. At the end it checks that:
the DLL needs only Windows system DLLs, every filter above is in it, soxr is in, and it is not a GPL build.

To build on GitHub: **Actions → Build and release → Run workflow**. With "Publish a GitHub release" ticked, it makes
the release `v<today>`.

## How an update works

1. Change a version in `build.sh` (the `SOURCES` list or `PLACEBO_COMMIT`) and its SHA-256.
2. Run the workflow. A new release `v<date>` appears.
3. In Lumen, change the release tag and the zip's SHA-256 in `windows/CMakeLists.txt`.

## Who made it

Built for Lumen by Utkarsh Tripathi. mpv, FFmpeg and the libraries are the work of their authors; this repo only
holds the build script. Thanks to the [media_kit](https://github.com/media-kit/media-kit) project, whose
[libmpv-win32-audio-build](https://github.com/media-kit/libmpv-win32-audio-build) showed the way.
