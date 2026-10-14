#!/usr/bin/env bash
# Builds Lumen's audio engine for Android: libmpv.so (mpv + FFmpeg, audio only) for
# arm64-v8a, armeabi-v7a and x86_64. The same sources, filters, soxr and bs2b as the
# Windows build (common.sh). Runs on Ubuntu (GitHub Actions ubuntu-24.04). Needs: curl,
# git, xz, zip, unzip, nasm, meson, ninja, cmake, pkg-config, python3.
#
#   ./build-android.sh    -> out-android/  (the release files)
set -euo pipefail

# --- Pinned versions --------------------------------------------------------------
# The NDK Flutter pins (ndkVersion 28.2.13676358). Google lists its SHA-1 as
# a7b54a5de87fecd125a17d54f73c446199e72a64 (repository2-3.xml).
NDK=android-ndk-r28c
NDK_URL=https://dl.google.com/android/repository/$NDK-linux.zip
NDK_SHA=dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f
API=26 # Lumen's minSdk (Android 8), also the first with AAudio
ABIS=${ABIS:-arm64-v8a armeabi-v7a x86_64}
# ----------------------------------------------------------------------------------

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/common.sh"
W=${WORK:-$ROOT/work-android}
OUT=$ROOT/out-android
JOBS=$(nproc)
mkdir -p "$W/dl" "$W/src" "$OUT/sources" "$OUT/LICENSES"
LOG=$OUT/CONFIGURE.txt
: > "$LOG"; : > "$OUT/SOURCES.txt"

# --- Toolchain and sources ----------------------------------------------------------
fetch "$NDK_URL" "$NDK_SHA" "$W/dl/$NDK-linux.zip"
[ -d "$W/$NDK" ] || unzip -q "$W/dl/$NDK-linux.zip" -d "$W"
TC=$W/$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
get_sources
echo "toolchain $NDK $NDK_URL sha256:$NDK_SHA" >> "$OUT/SOURCES.txt"
S=$W/src
# media_kit calls mpv_lavc_set_java_vm() (libmpv.so) to hand FFmpeg the JavaVM, which mpv's
# AudioTrack output needs. The same function as media_kit's own Android builds.
grep -q mpv_lavc_set_java_vm "$S/mpv/player/client.c" || cat >> "$S/mpv/player/client.c" <<'EOF'

#include <libavcodec/jni.h>
MPV_EXPORT int mpv_lavc_set_java_vm(void *vm);
int mpv_lavc_set_java_vm(void *vm) { return av_jni_set_java_vm(vm, NULL); }
EOF

en() { local -; set -f; local o=$1; shift; for x in $*; do printf -- "--enable-$o=%s " "$x"; done; }

for ABI in $ABIS; do
  case $ABI in
    arm64-v8a)   T=aarch64-linux-android;    FAM=aarch64; ARCH=aarch64; XC= ;;
    armeabi-v7a) T=armv7a-linux-androideabi; FAM=arm;     ARCH=arm;     XC=-mfpu=neon ;;
    x86_64)      T=x86_64-linux-android;     FAM=x86_64;  ARCH=x86_64;  XC= ;;
  esac
  CC=$TC/$T$API-clang; CXX=$TC/$T$API-clang++
  B=$W/$ABI; P=$B/prefix
  mkdir -p "$P/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=""
  # 16 KB pages (Android 15+); libc++ linked in statically; static libs' symbols kept private.
  LDF="-Wl,-z,max-page-size=16384 -Wl,--exclude-libs,ALL"
  cat > "$B/cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$TC/llvm-ar'
strip = '$TC/llvm-strip'
nasm = 'nasm'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$FAM'
cpu = '$FAM'
endian = 'little'
[built-in options]
c_args = ['-fPIC'${XC:+, '$XC'}]
cpp_args = ['-fPIC'${XC:+, '$XC'}]
c_link_args = [$(printf "'%s', " $LDF)'-lc++_static', '-lc++abi']  # libplacebo and HarfBuzz have C++ inside
cpp_link_args = [$(printf "'%s', " $LDF)'-static-libstdc++']
[properties]
pkg_config_libdir = '$P/lib/pkgconfig'
EOF
  MESON=(meson setup --cross-file "$B/cross.txt" --prefix "$P" --libdir lib --buildtype release
         --wrap-mode nodownload)
  LIBMESON=("${MESON[@]}" --default-library static)
  echo "=== $ABI"

  PKG="$ABI zlib"; rm -rf "$B/zlib"; cp -r "$S/zlib" "$B/zlib"; cd "$B/zlib"
  cfg env CHOST=$T CC="$CC" CFLAGS="-O2 -fPIC" AR="$TC/llvm-ar" RANLIB="$TC/llvm-ranlib" ./configure --prefix="$P" --static
  q make -j"$JOBS" install

  PKG="$ABI freetype"
  cfg "${LIBMESON[@]}" -Dauto_features=disabled -Dharfbuzz=disabled -Dzlib=disabled -Dbrotli=disabled \
      -Dbzip2=disabled -Dpng=disabled "$B/b-freetype" "$S/freetype"
  q ninja -C "$B/b-freetype" install

  PKG="$ABI fribidi"
  cfg "${LIBMESON[@]}" -Ddocs=false -Dbin=false -Dtests=false "$B/b-fribidi" "$S/fribidi"
  q ninja -C "$B/b-fribidi" install

  PKG="$ABI harfbuzz"
  cfg "${LIBMESON[@]}" -Dauto_features=disabled -Dfreetype=enabled -Draster=disabled -Dvector=disabled \
      -Dgpu=disabled -Dsubset=disabled -Dtests=disabled -Dutilities=disabled -Ddocs=disabled \
      "$B/b-harfbuzz" "$S/harfbuzz"
  q ninja -C "$B/b-harfbuzz" install

  PKG="$ABI libass"
  cfg "${LIBMESON[@]}" -Dauto_features=disabled -Drequire-system-font-provider=false "$B/b-libass" "$S/libass"
  q ninja -C "$B/b-libass" install

  PKG="$ABI libplacebo"
  cfg "${LIBMESON[@]}" -Dauto_features=disabled -Ddemos=false -Dtests=false "$B/b-libplacebo" "$S/libplacebo"
  q ninja -C "$B/b-libplacebo" install

  PKG="$ABI soxr"
  cfg cmake -S "$S/soxr" -B "$B/b-soxr" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$W/$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=$ABI \
      -DANDROID_PLATFORM=android-$API -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
      -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF -DHAVE_WORDS_BIGENDIAN_EXITCODE=1
  q ninja -C "$B/b-soxr" install

  PKG="$ABI libbs2b" # one C file; its autotools build wants libsndfile for tools we don't ship.
  { echo; echo "## $PKG"; echo "$T$API-clang -O2 -fPIC $XC -c src/bs2b.c; llvm-ar rcs libbs2b.a bs2b.o"; } >> "$LOG"
  "$CC" -O2 -fPIC $XC -c "$S/libbs2b/src/bs2b.c" -o "$B/bs2b.o" && "$TC/llvm-ar" rcs "$P/lib/libbs2b.a" "$B/bs2b.o"
  mkdir -p "$P/include/bs2b" && cp "$S"/libbs2b/src/{bs2b.h,bs2btypes.h,bs2bversion.h} "$P/include/bs2b/"
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libbs2b\nDescription: Bauer stereophonic-to-binaural DSP library\nVersion: 3.1.0\nLibs: -L${libdir} -lbs2b\nCflags: -I${includedir}/bs2b\n' "$P" > "$P/lib/pkgconfig/libbs2b.pc"

  # FFmpeg (LGPL v3: --enable-version3, never --enable-gpl). JNI on: mpv's AudioTrack output uses it.
  PKG="$ABI ffmpeg"; mkdir -p "$B/b-ffmpeg"; cd "$B/b-ffmpeg"
  cfg "$S/ffmpeg/configure" --prefix="$P" --target-os=android --arch=$ARCH --enable-cross-compile \
      --cc="$CC" --cxx="$CXX" --ar="$TC/llvm-ar" --nm="$TC/llvm-nm" --ranlib="$TC/llvm-ranlib" \
      --strip="$TC/llvm-strip" --pkg-config=pkg-config --pkg-config-flags=--static \
      --extra-cflags="-I$P/include $XC" --extra-ldflags="-L$P/lib" \
      --enable-version3 --disable-gpl --disable-nonfree \
      --enable-static --disable-shared --enable-pic --disable-programs --disable-doc --disable-debug \
      --enable-stripping --disable-autodetect --enable-pthreads --enable-jni --enable-zlib \
      --enable-libsoxr --enable-libbs2b \
      --disable-network --disable-avdevice --disable-everything \
      --enable-protocol=file \
      $(en filter "$FILTERS") $(en decoder "$DECODERS") $(en demuxer "$DEMUXERS") $(en parser "$PARSERS")
  q make -j"$JOBS"; q make install

  # mpv -> libmpv.so, audio outputs: AudioTrack, AAudio, OpenSL ES.
  PKG="$ABI mpv"
  cfg "${MESON[@]}" --default-library shared --prefer-static \
      -Dauto_features=disabled -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false \
      -Dbuild-date=false -Dzlib=enabled -Daudiotrack=enabled -Daaudio=enabled -Dopensles=enabled \
      -Dgl=disabled -Dcplugins=disabled -Dlua=disabled -Djavascript=disabled \
      "$B/b-mpv" "$S/mpv"
  q ninja -C "$B/b-mpv" install
  SO=$P/lib/libmpv.so
  "$TC/llvm-strip" -s "$SO"

  # Checks
  NEEDED=$("$TC/llvm-readelf" -d "$SO" | awk '/NEEDED/ {gsub(/[\[\]]/, "", $5); print $5}')
  echo "$ABI libmpv.so needs: $(echo $NEEDED)"
  for n in $NEEDED; do
    case $n in libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libOpenSLES.so) ;;
      *) echo "ERROR: $ABI libmpv.so needs $n, not an Android system library"; exit 1 ;;
    esac
  done
  "$TC/llvm-readelf" -d "$SO" | grep -q TEXTREL && { echo "ERROR: $ABI has text relocations"; exit 1; }
  "$TC/llvm-readelf" -lW "$SO" | awk '/LOAD/ && $NF != "0x4000" {bad=1} END {exit bad}' \
    || { echo "ERROR: $ABI is not 16 KB aligned"; exit 1; }
  "$TC/llvm-readelf" --dyn-syms -W "$SO" | grep -q ' mpv_lavc_set_java_vm$' \
    || { echo "ERROR: $ABI misses mpv_lavc_set_java_vm"; exit 1; }
  grep -qa -- "--enable-libsoxr" "$SO" || { echo "ERROR: soxr not in the build"; exit 1; }
  grep -qa -- "--enable-gpl" "$SO" && { echo "ERROR: GPL build"; exit 1; }
  mkdir -p "$OUT/lib/$ABI" && cp "$SO" "$OUT/lib/$ABI/libmpv.so"
done
for f in $FILTERS; do grep -qE "&ff_[av]f_$f," "$S/ffmpeg/libavfilter/filter_list.c" || { echo "ERROR: filter $f missing"; exit 1; }; done

# --- Licences ---------------------------------------------------------------------
copy_licences
cp "$ROOT/toolchain-licenses/LLVM-runtime-LICENSE.txt" "$OUT/LICENSES/" # the NDK's libc++, linked in

# --- Package ----------------------------------------------------------------------
TAG=${TAG:-v$(date -u +%Y.%m.%d)-android}
{
  echo "Lumen audio engine $TAG (Android: $ABIS, API $API)"
  echo "Built from $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown) of https://github.com/capsuleutkarsh-design/lumen-audio-engine"
  echo; cat "$OUT/SOURCES.txt"
} > "$OUT/BUILDINFO.txt"
mkdir -p "$OUT/include" && cp -r "$P/include/mpv" "$OUT/include/"
cd "$OUT"
ZIP=lumen-audio-engine-$TAG.zip
zip -qr "$ZIP" lib include LICENSES BUILDINFO.txt CONFIGURE.txt
git -C "$ROOT" archive --format=tar -o "$OUT/sources/lumen-audio-engine-build-scripts.tar" HEAD
tar -cf "lumen-audio-engine-$TAG-source.tar" sources LICENSES BUILDINFO.txt CONFIGURE.txt
sha256sum "$ZIP" lib/*/libmpv.so "lumen-audio-engine-$TAG-source.tar" > SHA256SUMS.txt
cat SHA256SUMS.txt
ls -la "$OUT" lib/*
