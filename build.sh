#!/usr/bin/env bash
# Builds Lumen's audio engine: libmpv-2.dll (mpv + FFmpeg, audio only, Windows x64).
# Runs on Ubuntu (GitHub Actions ubuntu-24.04). Needs: curl, git, xz, zip, nasm,
# meson, ninja, cmake, pkg-config, python3. Everything else is downloaded and checked
# against the SHA-256 below.
#
#   ./build.sh            -> out/  (the release files)
set -euo pipefail

# --- Pinned versions --------------------------------------------------------------
TOOLCHAIN=llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64
TOOLCHAIN_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/$TOOLCHAIN.tar.xz
TOOLCHAIN_SHA=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21

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
# ----------------------------------------------------------------------------------

ROOT=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$ROOT/work}
P=$W/prefix
OUT=$ROOT/out
JOBS=$(nproc)
mkdir -p "$W/dl" "$W/src" "$P/lib/pkgconfig" "$OUT/sources" "$OUT/LICENSES"
LOG=$OUT/CONFIGURE.txt
: > "$LOG"

fetch() { # url sha file
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet - 2>/dev/null && return 0
  curl -fL --retry 5 --retry-delay 5 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}
# Runs a build step quietly; shows the end of its output if it fails.
q() { "$@" > "$W/step.log" 2>&1 || { tail -80 "$W/step.log"; exit 1; }; }
# Logs the exact configure command into CONFIGURE.txt, then runs it.
cfg() { { echo; echo "## $PKG"; printf '%q ' "$@"; echo; } >> "$LOG"; "$@"; }

# --- Toolchain --------------------------------------------------------------------
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA" "$W/dl/$TOOLCHAIN.tar.xz"
[ -d "$W/$TOOLCHAIN" ] || tar xf "$W/dl/$TOOLCHAIN.tar.xz" -C "$W"
export PATH="$W/$TOOLCHAIN/bin:$PATH"
H=x86_64-w64-mingw32
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=""
# -static: no libc++/libunwind/winpthread DLLs. ASLR + DEP + high-entropy VA on.
HARDEN="-Wl,--dynamicbase,--nxcompat,--high-entropy-va"
cat > "$W/cross.txt" <<EOF
[binaries]
c = '$H-clang'
cpp = '$H-clang++'
ar = '$H-ar'
strip = '$H-strip'
windres = '$H-windres'
nasm = 'nasm'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[built-in options]
c_link_args = ['-static', '$HARDEN', '-lc++']  # libplacebo has C++ inside
cpp_link_args = ['-static', '$HARDEN']
[properties]
pkg_config_libdir = '$P/lib/pkgconfig'
EOF
MESON=(meson setup --cross-file "$W/cross.txt" --prefix "$P" --libdir lib --buildtype release
       --wrap-mode nodownload)
LIBMESON=("${MESON[@]}" --default-library static)

# --- Sources ----------------------------------------------------------------------
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
echo "toolchain $TOOLCHAIN $TOOLCHAIN_URL sha256:$TOOLCHAIN_SHA" >> "$OUT/SOURCES.txt"
S=$W/src

# --- Libraries ---------------------------------------------------------------------
PKG=zlib; cd "$S/zlib"
cfg env CHOST=$H CC=$H-clang AR=$H-ar RANLIB=$H-ranlib ./configure --prefix="$P" --static
q make -j"$JOBS" install

PKG=freetype
cfg "${LIBMESON[@]}" -Dauto_features=disabled -Dharfbuzz=disabled -Dzlib=disabled -Dbrotli=disabled \
    -Dbzip2=disabled -Dpng=disabled "$W/b-freetype" "$S/freetype"
q ninja -C "$W/b-freetype" install

PKG=fribidi
cfg "${LIBMESON[@]}" -Ddocs=false -Dbin=false -Dtests=false "$W/b-fribidi" "$S/fribidi"
q ninja -C "$W/b-fribidi" install

PKG=harfbuzz
cfg "${LIBMESON[@]}" -Dauto_features=disabled -Dfreetype=enabled -Draster=disabled -Dvector=disabled \
    -Dgpu=disabled -Dsubset=disabled -Dtests=disabled -Dutilities=disabled -Ddocs=disabled \
    "$W/b-harfbuzz" "$S/harfbuzz"
q ninja -C "$W/b-harfbuzz" install

PKG=libass
cfg "${LIBMESON[@]}" -Dauto_features=disabled -Drequire-system-font-provider=false "$W/b-libass" "$S/libass"
q ninja -C "$W/b-libass" install

PKG=libplacebo
cfg "${LIBMESON[@]}" -Dauto_features=disabled -Ddemos=false -Dtests=false "$W/b-libplacebo" "$S/libplacebo"
q ninja -C "$W/b-libplacebo" install

PKG=soxr
cfg cmake -S "$S/soxr" -B "$W/b-soxr" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=$H-clang -DCMAKE_RC_COMPILER=$H-windres \
    -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF \
    -DHAVE_WORDS_BIGENDIAN_EXITCODE=1
q ninja -C "$W/b-soxr" install

PKG=libbs2b # one C file; its autotools build wants libsndfile for tools we don't ship.
{ echo; echo "## $PKG"; echo "$H-clang -O2 -c src/bs2b.c; ar rcs libbs2b.a bs2b.o"; } >> "$LOG"
cd "$S/libbs2b" && $H-clang -O2 -c src/bs2b.c -o bs2b.o && $H-ar rcs "$P/lib/libbs2b.a" bs2b.o
mkdir -p "$P/include/bs2b" && cp src/bs2b.h src/bs2btypes.h src/bs2bversion.h "$P/include/bs2b/"
printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libbs2b\nDescription: Bauer stereophonic-to-binaural DSP library\nVersion: 3.1.0\nLibs: -L${libdir} -lbs2b\nCflags: -I${includedir}/bs2b\n' "$P" > "$P/lib/pkgconfig/libbs2b.pc"

# --- FFmpeg (LGPL v3: --enable-version3, never --enable-gpl) --------------------------
PKG=ffmpeg; cd "$S/ffmpeg"
en() { local -; set -f; local o=$1; shift; for x in $*; do printf -- "--enable-$o=%s " "$x"; done; }
cfg ./configure --prefix="$P" --target-os=mingw32 --arch=x86_64 --enable-cross-compile \
    --cross-prefix=$H- --cc=$H-clang --cxx=$H-clang++ --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-cflags="-I$P/include" --extra-ldflags="-L$P/lib" \
    --enable-version3 --disable-gpl --disable-nonfree \
    --enable-static --disable-shared --disable-programs --disable-doc --disable-debug --enable-stripping \
    --disable-autodetect --enable-w32threads --enable-zlib --enable-libsoxr --enable-libbs2b \
    --disable-network --disable-avdevice --disable-everything \
    --enable-protocol=file \
    $(en filter "$FILTERS") $(en decoder "$DECODERS") $(en demuxer "$DEMUXERS") $(en parser "$PARSERS")
q make -j"$JOBS"; q make install

# --- mpv -> libmpv-2.dll -------------------------------------------------------------
PKG=mpv
cfg "${MESON[@]}" --default-library shared --prefer-static \
    -Dauto_features=disabled -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false \
    -Dbuild-date=false -Dwin32-threads=enabled -Dwasapi=enabled -Dzlib=enabled \
    -Dgl=disabled -Dcplugins=disabled -Dlua=disabled -Djavascript=disabled -Dwin32-smtc=disabled \
    "$W/b-mpv" "$S/mpv"
q ninja -C "$W/b-mpv" install
DLL=$P/bin/libmpv-2.dll
$H-strip -s "$DLL"

# --- Checks -----------------------------------------------------------------------
IMPORTS=$($H-objdump -p "$DLL" | awk '/DLL Name:/ {print $3}')
echo "libmpv-2.dll imports: $IMPORTS"
if echo "$IMPORTS" | grep -qiE '^(lib|zlib|avcodec|avformat|avutil|swresample|swscale|avfilter|soxr)'; then
  echo "ERROR: the DLL depends on a non-system DLL"; exit 1
fi
for f in $FILTERS; do grep -qaP "\x00$f\x00" "$DLL" || { echo "ERROR: filter $f missing"; exit 1; }; done
grep -qa -- "--enable-libsoxr" "$DLL" || { echo "ERROR: soxr not in the build"; exit 1; }
grep -qa -- "--enable-gpl" "$DLL" && { echo "ERROR: GPL build"; exit 1; }

# --- Licences ---------------------------------------------------------------------
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
cp "$ROOT"/toolchain-licenses/* "$L/"

# --- Package ----------------------------------------------------------------------
TAG=${TAG:-v$(date -u +%Y.%m.%d)}
{
  echo "Lumen audio engine $TAG"
  echo "Built from $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown) of https://github.com/capsuleutkarsh-design/lumen-audio-engine"
  echo; cat "$OUT/SOURCES.txt"
} > "$OUT/BUILDINFO.txt"
cp "$DLL" "$OUT/libmpv-2.dll"
mkdir -p "$OUT/include" && cp -r "$P/include/mpv" "$OUT/include/"
cd "$OUT"
ZIP=lumen-audio-engine-$TAG-win64.zip
zip -qr "$ZIP" libmpv-2.dll include LICENSES BUILDINFO.txt CONFIGURE.txt
git -C "$ROOT" archive --format=tar -o "$OUT/sources/lumen-audio-engine-build-scripts.tar" HEAD
tar -cf "lumen-audio-engine-$TAG-source.tar" sources LICENSES BUILDINFO.txt CONFIGURE.txt
sha256sum "$ZIP" libmpv-2.dll "lumen-audio-engine-$TAG-source.tar" > SHA256SUMS.txt
cat SHA256SUMS.txt
ls -la "$OUT"
