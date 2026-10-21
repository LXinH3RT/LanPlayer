#!/usr/bin/env bash
# Cross-compiles FFmpeg and libsmb2 for Android into native/third_party/.
#
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build_android_deps.sh [abi...]
#
# Default ABIs: arm64-v8a armeabi-v7a.  Output layout matches what
# native/CMakeLists.txt expects (see docs/build.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/native/third_party"
WORK="${WORK:-$ROOT/build/deps}"
API="${API:-26}"
FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.1}"
LIBSMB2_VERSION="${LIBSMB2_VERSION:-v4.0.0}"

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" ]]; then
  echo "ANDROID_NDK_HOME is not set" >&2
  exit 1
fi
HOST_TAG="linux-x86_64"
[[ "$(uname)" == "Darwin" ]] && HOST_TAG="darwin-x86_64"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"

ABIS=("${@:-}")
if [[ -z "${ABIS[0]:-}" ]]; then
  ABIS=(arm64-v8a armeabi-v7a)
fi

mkdir -p "$WORK" "$OUT/ffmpeg/android" "$OUT/libsmb2/android"

fetch() { # url dest
  if [[ ! -e "$2" ]]; then
    echo "== fetching $1"
    # GitHub runners occasionally fail to resolve ffmpeg.org; retry instead of
    # failing the whole job on one DNS hiccup.
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$1" -o "$2"
  fi
}

# ffmpeg.org has been flaky from GitHub's Linux runners ("Could not resolve
# host: ffmpeg.org", curl exit 6), so fall back to the GitHub mirror of the same
# release tag and normalise the directory name.
fetch_ffmpeg() {
  if [[ -d "$WORK/ffmpeg-${FFMPEG_VERSION}" ]]; then return 0; fi
  if ! fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
      "$WORK/ffmpeg.tar.xz"; then
    echo "== ffmpeg.org unreachable, falling back to the GitHub mirror" >&2
    local tag="n${FFMPEG_VERSION}"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
      "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/${tag}" \
      -o "$WORK/ffmpeg.tar.gz"
    tar xf "$WORK/ffmpeg.tar.gz" -C "$WORK"
    # GitHub names the archive directory after the tag: FFmpeg-n6.1.1.
    local dir
    dir=$(find "$WORK" -maxdepth 1 -type d -name 'FFmpeg-*' | head -n1)
    [[ -n "$dir" ]] || { echo "ffmpeg tarball extracted nowhere" >&2; exit 1; }
    mv "$dir" "$WORK/ffmpeg-${FFMPEG_VERSION}"
    return 0
  fi
  tar xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
}
fetch_ffmpeg

if [[ ! -d "$WORK/libsmb2" ]]; then
  git clone --depth 1 --branch "$LIBSMB2_VERSION" https://github.com/sahlberg/libsmb2 "$WORK/libsmb2"
fi

for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a)   ARCH=arm64;  CPU=armv8-a; TRIPLE=aarch64-linux-android ;;
    armeabi-v7a) ARCH=arm;    CPU=armv7-a; TRIPLE=armv7a-linux-androideabi ;;
    x86_64)      ARCH=x86_64; CPU=x86-64;  TRIPLE=x86_64-linux-android ;;
    *) echo "unsupported ABI $ABI" >&2; exit 1 ;;
  esac
  CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
  CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  PREFIX="$OUT/ffmpeg/android/x-$ABI"

  echo "== FFmpeg for $ABI"
  rm -rf "$WORK/ffbuild-$ABI"
  mkdir -p "$WORK/ffbuild-$ABI"
  pushd "$WORK/ffbuild-$ABI" >/dev/null
  "$WORK/ffmpeg-${FFMPEG_VERSION}/configure" \
    --prefix="$PREFIX" --target-os=android --arch="$ARCH" --cpu="$CPU" \
    --enable-cross-compile --sysroot="$TOOLCHAIN/sysroot" \
    --cc="$CC" --cxx="$CXX" \
    --ar="$TOOLCHAIN/bin/llvm-ar" --nm="$TOOLCHAIN/bin/llvm-nm" \
    --strip="$TOOLCHAIN/bin/llvm-strip" --ranlib="$TOOLCHAIN/bin/llvm-ranlib" \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-avdevice --disable-postproc --disable-swscale-alpha \
    --enable-jni --enable-mediacodec \
    --enable-filter=atempo,yadif,scale,format,aresample \
    --enable-demuxer=matroska,mov,avi,mpegts,flv,mp3,aac,flac,wav,ogg,ass,srt,webvtt \
    --enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,aac,mp3,ac3,eac3,dts,flac,opus,vorbis,ass,subrip,webvtt \
    --enable-parser=h264,hevc,vp9,av1,mpegaudio,aac \
    --enable-protocol=file,http,https,tcp,tls \
    --enable-small
  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  make install
  popd >/dev/null

  # Layout expected by CMake: <root>/android/<abi>/lib/<abi>/*.so + include/
  mkdir -p "$OUT/ffmpeg/android/$ABI/lib/$ABI"
  cp "$PREFIX"/lib/*.so "$OUT/ffmpeg/android/$ABI/lib/$ABI/"
  cp -r "$PREFIX/include" "$OUT/ffmpeg/android/$ABI/include"

  echo "== libsmb2 for $ABI"
  rm -rf "$WORK/smb-$ABI"
  # libsmb2's CMake probes for OpenSSL and GSSAPI.  The NDK sysroot has neither,
  # so find_package() leaves OPENSSL_INCLUDE_DIR/OPENSSL_LIBRARIES as NOTFOUND
  # and the generate step dies with "The following variables are used in this
  # project, but they are set to NOTFOUND: OPENSSL_INCLUDE_DIR".  We only need
  # plain SMB2/SMB3 (no TLS, no Kerberos), so turn both probes off explicitly.
  # CMAKE_POLICY_VERSION_MINIMUM covers libsmb2's cmake_minimum_required(2.8.12)
  # being rejected by CMake >= 4.
  cmake -S "$WORK/libsmb2" -B "$WORK/smb-$ABI" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_INSTALL_PREFIX="$OUT/libsmb2/android" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
  cmake --build "$WORK/smb-$ABI" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  # libsmb2's install puts everything in the same prefix; copy per ABI.
  mkdir -p "$OUT/libsmb2/android/lib/$ABI" "$OUT/libsmb2/android/include"
  find "$WORK/smb-$ABI" -name 'libsmb2*.so*' -exec cp -a {} "$OUT/libsmb2/android/lib/$ABI/" \;
  cp -r "$WORK/libsmb2/include/." "$OUT/libsmb2/android/include/"

  # Gradle only packages libraries that live in a jniLibs directory, and the
  # CMake IMPORTED targets above are not copied into the APK by AGP.  Stage a
  # jniLibs-friendly tree (<root>/<abi>/*.so) so app/build.gradle.kts can point
  # sourceSets.main.jniLibs at it.
  mkdir -p "$OUT/jniLibs/$ABI"
  cp "$PREFIX"/lib/*.so "$OUT/jniLibs/$ABI/"
  find "$WORK/smb-$ABI" -name 'libsmb2*.so*' -exec cp -a {} "$OUT/jniLibs/$ABI/" \;
done

echo "done: $OUT"
