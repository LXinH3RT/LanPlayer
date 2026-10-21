#!/usr/bin/env bash
# Builds FFmpeg + libsmb2 + the LanPlayer C core for iOS (device + simulator)
# and macOS into native/third_party/, matching the layout from docs/build.md.
#
#   ./scripts/build_apple_deps.sh            # all three slices
#   SLICES=iphoneos ./scripts/build_apple_deps.sh
#   ARCHS=x86_64 ./scripts/build_apple_deps.sh   # Intel Mac
#
# Output layout (each lib is a universal archive when several slices ran):
#   native/third_party/ffmpeg/apple/{include,lib}     libav*.a, libsw*.a
#   native/third_party/libsmb2/apple/{include,lib}    libsmb2.a
#   native/third_party/lanplayer/apple/lib            liblanplayer.a  <- our C core
#
# The core is built here (rather than by CocoaPods) on purpose: this script
# already has to run on the Mac for FFmpeg and libsmb2, and a plain `ar` of our
# own 16 translation units is far easier to debug than a pod that globs sources
# from outside its own directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/native/third_party"
WORK="${WORK:-$ROOT/build/deps}"
FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.1}"
LIBSMB2_VERSION="${LIBSMB2_VERSION:-v4.0.0}"
MIN_IOS="${MIN_IOS:-13.0}"
MIN_MACOS="${MIN_MACOS:-11.0}"
# One platform family per run.  On Apple silicon iphoneos, iphonesimulator and
# macosx are all arm64, and lipo refuses to pack two slices with the same
# architecture into one fat archive ("have the same architectures (arm64)")
# - and the podspecs all point at native/third_party/*/apple/lib, so there is
# only room for one family's archives at a time.  Re-run with a different
# SLICES value to switch target:
#   SLICES=macosx          macOS (default: the usual desktop build)
#   SLICES=iphoneos        iOS device
#   SLICES=iphonesimulator iOS simulator
SLICES="${SLICES:-macosx}"
# Simulator slices: arm64 for Apple-silicon Macs, x86_64 for Intel ones.
# Override with ARCHS="arm64 x86_64" to build a fat simulator archive.
ARCHS="${ARCHS:-arm64}"

mkdir -p "$WORK" "$OUT/ffmpeg/apple" "$OUT/libsmb2/apple"

fetch() {
  # GitHub runners occasionally fail to resolve ffmpeg.org / github.com; retry
  # a few times instead of failing the whole job on one DNS hiccup.
  [[ -e "$2" ]] || {
    echo "== fetching $1"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$1" -o "$2"
  }
}

# ffmpeg.org is unreachable from the hosted runners often enough to be a
# nuisance ("Could not resolve host: ffmpeg.org").  Fall back to the GitHub
# mirror of the same release tag when that happens.
if [[ ! -d "$WORK/ffmpeg-${FFMPEG_VERSION}" ]]; then
  if ! fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
      "$WORK/ffmpeg.tar.xz"; then
    echo "== ffmpeg.org unreachable, falling back to the GitHub mirror" >&2
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
      "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n${FFMPEG_VERSION}" \
      -o "$WORK/ffmpeg.tar.gz"
    tar xf "$WORK/ffmpeg.tar.gz" -C "$WORK"
    # GitHub names the archive directory after the tag: FFmpeg-n6.1.1.
    dir=$(find "$WORK" -maxdepth 1 -type d -name 'FFmpeg-*' | head -n1)
    [[ -n "$dir" ]] || { echo "ffmpeg tarball extracted nowhere" >&2; exit 1; }
    mv "$dir" "$WORK/ffmpeg-${FFMPEG_VERSION}"
  else
    tar xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
  fi
fi
if [[ ! -d "$WORK/libsmb2" ]]; then
  git clone --depth 1 --branch "$LIBSMB2_VERSION" https://github.com/sahlberg/libsmb2 "$WORK/libsmb2"
fi

slice_sdk() {
  case "$1" in
    iphoneos) echo "iphoneos" ;;
    iphonesimulator) echo "iphonesimulator" ;;
    macosx) echo "macosx" ;;
    *) echo "unknown slice $1" >&2; exit 1 ;;
  esac
}

for SLICE in $SLICES; do
  SDK="$(slice_sdk "$SLICE")"
  SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  DEPLOY_TARGET="$([[ "$SDK" == iphone* ]] && echo "$MIN_IOS" || echo "$MIN_MACOS")"
  # First arch is the primary one used for the configure step; extra arches are
  # only lipo'ed in later (FFmpeg/libsmb2 builds are per-arch here).
  PRIMARY_ARCH="${ARCHS%% *}"
  if [[ "$SDK" == iphonesimulator ]]; then
    # 模拟器必须用 -mios-simulator-version-min；用 -miphoneos-version-min 会在
    # clang 里触发 "overriding deployment target" 警告，个别 Xcode 版本会把它升级成错误。
    PLATFORM_FLAG="-mios-simulator-version-min=$DEPLOY_TARGET"
  elif [[ "$SDK" == iphoneos ]]; then
    PLATFORM_FLAG="-miphoneos-version-min=$DEPLOY_TARGET"
  else
    PLATFORM_FLAG="-mmacosx-version-min=$DEPLOY_TARGET"
  fi
  CC="xcrun -sdk $SDK clang -arch $PRIMARY_ARCH $PLATFORM_FLAG"

  PREFIX="$WORK/ff-$SLICE"
  # FFmpeg 编一次要十几分钟，而改脚本后通常只是后面某一步失败。
  # 已有产物就跳过；真要重编用 FORCE=1 ./scripts/build_apple_deps.sh。
  if [[ -f "$PREFIX/lib/libavcodec.a" && "${FORCE:-0}" != "1" ]]; then
    echo "== FFmpeg $SLICE (cached)"
  else
  echo "== FFmpeg $SLICE"
  rm -rf "$WORK/ffbuild-$SLICE"
  mkdir -p "$WORK/ffbuild-$SLICE"
  pushd "$WORK/ffbuild-$SLICE" >/dev/null
  "$WORK/ffmpeg-${FFMPEG_VERSION}/configure" \
    --prefix="$PREFIX" --target-os=darwin --arch="$PRIMARY_ARCH" \
    --enable-cross-compile --sysroot="$SYSROOT" \
    --cc="$CC" --pkg-config=/usr/bin/false \
    --enable-static --disable-shared --disable-programs --disable-doc \
    --disable-avdevice --disable-postproc \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-filter=atempo,yadif,scale,format,aresample \
    --enable-demuxer=matroska,mov,avi,mpegts,flv,mp3,aac,flac,wav,ogg,ass,srt,webvtt \
    --enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,aac,mp3,ac3,eac3,dts,flac,opus,vorbis,ass,subrip,webvtt \
    --enable-protocol=file,http,https,tcp,tls
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd >/dev/null
  fi

  echo "== libsmb2 $SLICE"
  rm -rf "$WORK/smb-$SLICE"
  # 为什么必须禁掉 GSSAPI / OpenSSL：
  #   libsmb2 的 CMakeLists 无条件 find_package(GSSAPI) + find_package(OpenSSL)。
  #   macOS 自带 libgssapi_krb5 与 gssapi/gssapi.h，于是 HAVE_LIBKRB5 被定义，
  #   lib/krb5-wrapper.c 去用 gss_const_OID / gss_acquire_cred_with_password /
  #   gss_set_neg_mechs / gss_inquire_sec_context_by_oid / GSS_C_INQ_SSPI_SESSION_KEY /
  #   gss_release_buffer_set —— 这些是 MIT/Heimdal krb5 的扩展，Apple 的 GSS.framework
  #   没有，Xcode 15 起隐式函数声明又是硬错误，直接 18 个 error。
  #   装了 Homebrew 的话 OpenSSL 也会被找到，静态库里就留下 libcrypto 符号，
  #   而 app 并不链接它，最后是链接期错误。
  #   我们只用 NTLM（用户名 + 密码），不需要 Kerberos 与 SMB3 加密传输，
  #   所以两个都关掉，让 libsmb2 用它自带的 AES/MD4/HMAC 实现。
  #   CMAKE_DISABLE_FIND_PACKAGE_<pkg> 是 CMake 标准缓存变量，能让对应的
  #   find_package 直接失败（不是致命错误），比 -DGSSAPI_FOUND=FALSE 可靠。
  # CMAKE_POLICY_VERSION_MINIMUM=3.5：libsmb2 v4.0.0 的 cmake_minimum_required 是 3.2，
  # 而 CMake 4.x（Homebrew 现在装的就是 4.x）已经删掉了 <3.5 的兼容性，配置会直接报
  # "Compatibility with CMake < 3.5 has been removed"。这个变量是 CMake 3.31+ 加的开关，
  # 老版本 CMake 不认识它、只会打一句 "Manually-specified variables were not used" 警告，
  # 所以无条件传是安全的。
  cmake -S "$WORK/libsmb2" -B "$WORK/smb-$SLICE" \
    -DCMAKE_SYSTEM_NAME="$([[ "$SDK" == iphone* ]] && echo iOS || echo Darwin)" \
    -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES="$PRIMARY_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$WORK/smb-out-$SLICE" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
  cmake --build "$WORK/smb-$SLICE" -j"$(sysctl -n hw.ncpu)"
  cmake --install "$WORK/smb-$SLICE"

  # ---------------------------------------------------------------
  # LanPlayer C core -> liblanplayer.a
  #
  # 只编平台无关的 13 个核心文件 + platform/apple 的 3 个适配层。
  # platform/android、platform/win32、platform/stub 不能进来：
  # 前两个要各自平台的系统头，stub 会与 apple 定义重名。
  # ---------------------------------------------------------------
  echo "== LanPlayer core $SLICE"
  LP_BUILD="$WORK/lp-$SLICE"
  rm -rf "$LP_BUILD"
  mkdir -p "$LP_BUILD"

  LP_SOURCES=(
    "$ROOT/native/src/util/lp_str.c"
    "$ROOT/native/src/util/lp_log.c"
    "$ROOT/native/src/core/queue.c"
    "$ROOT/native/src/core/audio_ring.c"
    "$ROOT/native/src/core/demux.c"
    "$ROOT/native/src/core/video.c"
    "$ROOT/native/src/core/audio.c"
    "$ROOT/native/src/core/subtitle.c"
    "$ROOT/native/src/core/player.c"
    "$ROOT/native/src/source/url.c"
    "$ROOT/native/src/source/io.c"
    "$ROOT/native/src/source/smb.c"
    "$ROOT/native/src/source/file.c"
    "$ROOT/native/src/platform/apple/videotoolbox_decoder.c"
    "$ROOT/native/src/platform/apple/coreaudio_sink.c"
    "$ROOT/native/src/platform/apple/apple_texture.c"
  )

  LP_OBJECTS=()
  for SRC in "${LP_SOURCES[@]}"; do
    OBJ="$LP_BUILD/$(basename "${SRC%.c}").o"
    # shellcheck disable=SC2086
    $CC -std=gnu11 -O2 -fPIC -fblocks \
      -DNDEBUG \
      -DLP_PLATFORM_APPLE=1 \
      -DLP_HAVE_ICONV=1 \
      -DLP_HAVE_SMB2=1 \
      -DLP_ENABLE_HTTP=1 \
      -D_FILE_OFFSET_BITS=64 \
      -D_GNU_SOURCE \
      -I"$ROOT/native/include" \
      -I"$ROOT/native/src" \
      -I"$ROOT/native/src/source" \
      -I"$WORK/ff-$SLICE/include" \
      -I"$WORK/libsmb2/include" \
      -c "$SRC" -o "$OBJ"
    LP_OBJECTS+=("$OBJ")
  done
  xcrun --sdk "$SDK" libtool -static -o "$LP_BUILD/liblanplayer.a" "${LP_OBJECTS[@]}"
  echo "== ar liblanplayer.a ($SLICE) <- ${#LP_OBJECTS[@]} object(s)"
done

# Merge the slices: lipo every static lib into one universal archive.
# $2 is the output directory: libsmb2 must land in libsmb2/apple/lib, because
# the podspecs point LIBRARY_SEARCH_PATHS at three separate directories.
merge() { # name outdir
  local name="$1"
  local outdir="$2"
  local inputs=()
  for SLICE in $SLICES; do
    local f
    f=$(find "$WORK/ff-$SLICE/lib" "$WORK/smb-out-$SLICE/lib" -name "lib${name}.a" 2>/dev/null | head -n1)
    [[ -n "$f" ]] && inputs+=("$f")
  done
  if [[ ${#inputs[@]} -eq 0 ]]; then
    echo "warning: lib${name}.a not found, skipped" >&2
    return 0
  fi
  mkdir -p "$outdir"
  lipo -create "${inputs[@]}" -output "$outdir/lib${name}.a"
  echo "== lipo lib${name}.a <- ${#inputs[@]} slice(s)"
}

mkdir -p "$OUT/ffmpeg/apple/lib" "$OUT/ffmpeg/apple/include" \
         "$OUT/libsmb2/apple/lib" "$OUT/libsmb2/apple/include" \
         "$OUT/lanplayer/apple/lib"
for LIB in avformat avcodec avutil swresample swscale avfilter; do
  merge "$LIB" "$OUT/ffmpeg/apple/lib"
done
merge smb2 "$OUT/libsmb2/apple/lib"

# Our own core: one liblanplayer.a per slice, merged the same way (arch-deduped,
# so iphoneos arm64 wins over iphonesimulator arm64).
LP_INPUTS=()
LP_SEEN=" "
for SLICE in $SLICES; do
  f="$WORK/lp-$SLICE/liblanplayer.a"
  [[ -f "$f" ]] || continue
  arch=$(lipo -archs "$f" 2>/dev/null | tr ' ' '\n' | head -n1)
  if [[ -n "$arch" && "$LP_SEEN" == *" $arch "* ]]; then
    echo "== lipo liblanplayer.a: skipping $SLICE (duplicate $arch)" >&2
    continue
  fi
  [[ -n "$arch" ]] && LP_SEEN+="$arch "
  LP_INPUTS+=("$f")
done
if [[ ${#LP_INPUTS[@]} -eq 1 ]]; then
  cp "${LP_INPUTS[0]}" "$OUT/lanplayer/apple/lib/liblanplayer.a"
  echo "== copy liblanplayer.a <- 1 slice"
elif [[ ${#LP_INPUTS[@]} -gt 1 ]]; then
  lipo -create "${LP_INPUTS[@]}" -output "$OUT/lanplayer/apple/lib/liblanplayer.a"
  echo "== lipo liblanplayer.a <- ${#LP_INPUTS[@]} slice(s)"
else
  echo "warning: liblanplayer.a not built, skipped" >&2
fi

# lanplayer_core.podspec 里 -lsmb2 之外的 FFmpeg 7 个库都按顺序列出，这里
# 多导出一个 libpostproc 也没用（configure 里 --disable-postproc）。
# avdevice 同理：核心代码从来没调用过 avdevice_*（用 grep 确认过），
# 所以不需要 avdevice，podspec 里也不要列它。

# Headers: identical across slices, take the first.
# 用 install 版的头（$WORK/smb-out-*/include）而不是源码树的 include/：
# 源码树里那些（asprintf.h、libsmb2-private.h、Makefile.am、msvc/…）是本仓库
# 自己编 libsmb2 时才要的，app 侧只需要 <smb2/libsmb2.h>。
FIRST_SLICE="${SLICES%% *}"
rm -rf "$OUT/ffmpeg/apple/include" "$OUT/libsmb2/apple/include"
mkdir -p "$OUT/ffmpeg/apple/include" "$OUT/libsmb2/apple/include"
cp -r "$WORK/ff-$FIRST_SLICE/include/." "$OUT/ffmpeg/apple/include/"
if [[ -d "$WORK/smb-out-$FIRST_SLICE/include" ]]; then
  cp -r "$WORK/smb-out-$FIRST_SLICE/include/." "$OUT/libsmb2/apple/include/"
else
  # 老版本 libsmb2 的 install() 只装库不装头；退回到源码树里的 smb2/ 子目录。
  cp -r "$WORK/libsmb2/include/." "$OUT/libsmb2/apple/include/"
fi

echo "done: $OUT"
