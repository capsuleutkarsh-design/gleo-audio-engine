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

# ----------------------------------------------------------------------------------

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/common.sh"
W=${WORK:-$ROOT/work}
P=$W/prefix
OUT=$ROOT/out
JOBS=$(nproc)
mkdir -p "$W/dl" "$W/src" "$P/lib/pkgconfig" "$OUT/sources" "$OUT/LICENSES"
LOG=$OUT/CONFIGURE.txt
: > "$LOG"

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
get_sources
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
for f in $FILTERS; do grep -qE "&ff_[av]f_$f," "$S/ffmpeg/libavfilter/filter_list.c" || { echo "ERROR: filter $f missing"; exit 1; }; done
grep -qa -- "--enable-libsoxr" "$DLL" || { echo "ERROR: soxr not in the build"; exit 1; }
grep -qa -- "--enable-gpl" "$DLL" && { echo "ERROR: GPL build"; exit 1; }

# --- Licences ---------------------------------------------------------------------
copy_licences
cp "$ROOT"/toolchain-licenses/* "$OUT/LICENSES/"

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
