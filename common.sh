# Shared by build.sh (Windows) and build-android.sh: the pinned sources, the FFmpeg
# component lists, and small helpers. Sourced, not run.

# name|version|url|sha256 (the file name in sources/ is <name>-<version>.<ext of url>)
SOURCES=(
  "zlib|1.3.2|https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.xz|d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3"
  "freetype|2.14.3|https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz|36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
  "fribidi|1.0.17|https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz|6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2"
  "harfbuzz|14.6.0|https://github.com/harfbuzz/harfbuzz/releases/download/14.6.0/harfbuzz-14.6.0.tar.xz|d07a007327277708a2a73ae437887cdbaf282937f6d03ca5467723e9099af586"
  "libass|0.17.5|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
  "soxr|0.1.3|https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz|b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889"
  "libbs2b|3.1.0|https://downloads.sourceforge.net/project/bs2b/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz|6aaafd81aae3898ee40148dd1349aab348db9bfae9767d0e66e0b07ddd4b2528"
  "ffmpeg|8.1.3|https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz|7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
  "mpv|0.41.0|https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz|ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
)
# libplacebo needs its git submodules, so it is cloned at an exact commit and packed here.
PLACEBO_VER=7.360.1
PLACEBO_GIT=https://code.videolan.org/videolan/libplacebo.git
PLACEBO_COMMIT=cee9b076f2c63104ccfd497fa79c39a867293ec4

# The audio filters Lumen uses (plus the ones mpv itself needs).
FILTERS="aformat anull aresample asplit amix adelay aecho afir alimiter acompressor
  allpass bandpass bass biquad crossfeed dynaudnorm ebur128 equalizer extrastereo
  firequalizer headphone highpass highshelf loudnorm lowpass lowshelf pan stereotools
  superequalizer treble volume bs2b
  format null overlay"
DECODERS="aac* ac3 eac3 alac als ape atrac* cook dca dsd* flac gsm* mlp truehd mp1* mp2* mp3*
  mpc* opus ra* ralf shorten tak tta vorbis wavpack wma* pcm* adpcm*
  mjpeg ljpeg jpegls png gif bmp tiff webp"
DEMUXERS="aac ac3 eac3 aiff ape asf au avi caf dsf dts dtshd flac flv iff loas matroska mlp
  truehd mov mp3 mpc mpc8 ogg pcm* rm shorten tak tta w64 wav wv xwma"
PARSERS="aac* ac3 cook dca flac gsm mlp mpegaudio opus tak vorbis mjpeg png"

fetch() { # url sha file
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet - 2>/dev/null && return 0
  curl -fL --retry 5 --retry-delay 5 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}
# Runs a build step quietly; shows the end of its output if it fails.
q() { "$@" > "$W/step.log" 2>&1 || { tail -80 "$W/step.log"; exit 1; }; }
# Logs the exact configure command into CONFIGURE.txt, then runs it.
cfg() { { echo; echo "## $PKG"; printf '%q ' "$@"; echo; } >> "$LOG"; "$@"; }

# Downloads and checks every source into $OUT/sources, unpacks it into $W/src.
get_sources() {
  for s in "${SOURCES[@]}"; do
    IFS='|' read -r name ver url sha <<< "$s"
    ext=${url##*.tar.}; f="$OUT/sources/$name-$ver.tar.$ext"
    fetch "$url" "$sha" "$f"
    mkdir -p "$W/src/$name" && tar xf "$f" -C "$W/src/$name" --strip-components=1
    echo "$name $ver $url sha256:$sha" >> "$OUT/SOURCES.txt"
  done
  if [ ! -d "$W/src/libplacebo/.git" ]; then
    git clone --quiet "$PLACEBO_GIT" "$W/src/libplacebo"
    git -C "$W/src/libplacebo" checkout --quiet "$PLACEBO_COMMIT"
    git -C "$W/src/libplacebo" submodule update --init --quiet
  fi
  tar --exclude=.git --sort=name --mtime=@0 --owner=0 --group=0 -C "$W/src" -cJf "$OUT/sources/libplacebo-$PLACEBO_VER.tar.xz" libplacebo
  echo "libplacebo $PLACEBO_VER $PLACEBO_GIT commit:$PLACEBO_COMMIT (with submodules: $(git -C "$W/src/libplacebo" submodule status | awk '{print $2"@"$1}' | tr '\n' ' '))" >> "$OUT/SOURCES.txt"
}

# The licence texts of every part, into $OUT/LICENSES (the toolchain's are added by each script).
copy_licences() {
  L=$OUT/LICENSES
  mkdir -p "$L"
  cp "$S/ffmpeg/COPYING.LGPLv3" "$L/LGPL-3.0.txt"; cp "$S/ffmpeg/COPYING.GPLv3" "$L/GPL-3.0.txt"
  cp "$S/ffmpeg/COPYING.LGPLv2.1" "$L/LGPL-2.1.txt"
  cp "$S/ffmpeg/LICENSE.md" "$L/FFmpeg-LICENSE.md"
  cp "$S/mpv/Copyright" "$L/mpv-Copyright.txt"
  cp "$S/libplacebo/LICENSE" "$L/libplacebo-LICENSE.txt"
  for f in "$S"/libplacebo/3rdparty/fast_float/LICENSE-*; do cp "$f" "$L/fast_float-$(basename "$f").txt"; done
  cp "$S/libass/COPYING" "$L/libass-COPYING.txt"
  cp "$S/harfbuzz/COPYING" "$L/harfbuzz-COPYING.txt"
  cp "$S/freetype/LICENSE.TXT" "$L/freetype-LICENSE.txt"; cp "$S/freetype/docs/FTL.TXT" "$L/freetype-FTL.txt"
  cp "$S/fribidi/COPYING" "$L/fribidi-COPYING.txt"
  cp "$S/zlib/LICENSE" "$L/zlib-LICENSE.txt"
  cp "$S/soxr/LICENCE" "$L/soxr-LICENCE.txt"; cp "$S/soxr/COPYING.LGPL" "$L/soxr-COPYING.LGPL.txt"
  cp "$S/libbs2b/COPYING" "$L/libbs2b-COPYING.txt"
}
