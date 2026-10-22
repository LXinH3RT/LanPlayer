# 构建指南

本仓库只包含源码：FFmpeg 与 libsmb2 需要按下面的步骤自己编译，产物放进
`native/third_party/`（已被 `.gitignore` 忽略）。

## 0\. 目录约定

```
native/third_party/
├─ ffmpeg/
│  ├─ android/arm64-v8a/{include,lib/arm64-v8a/*.so}
│  ├─ android/armeabi-v7a/{include,lib/armeabi-v7a/*.so}
│  ├─ apple/macosx/{include,lib/*.a}          # macOS
│  ├─ apple/iphoneos/{include,lib/*.a}        # iOS 真机
│  ├─ apple/iphonesimulator/{include,lib/*.a} # iOS / iPadOS 模拟器
│  ├─ apple/{include,lib/*.a}                 # 最近一次构建的副本（兜底，带 .family 标记）
│  └─ desktop/{include,lib/*.a}        # 可选：Windows/Linux 本地调试
└─ libsmb2/
   ├─ android/{include,lib/<abi>/libsmb2.so}
   └─ apple/<family>/{include,lib/libsmb2.a}
```

Apple 三个平台族各写**自己的目录**（`<family>` = `macosx` / `iphoneos` / `iphonesimulator`）。
两个 podspec 用 `$(PLATFORM_NAME)` 自动选目录，所以 macOS 与 iOS 的库可以在同一个工作副本里共存，
交错构建不会互相覆盖；`apple/lib` 那份扁平副本只是给老路径兜底。

`native/third_party/` 整个目录都是生成物（几百 MB），不进 git。删了重新跑
`scripts\build_windows.ps1`（Windows）或 `SLICES=macosx ./scripts/build_apple_deps.sh`（Apple）即可。
README 的「哪些东西删了还能重建」有完整的对照表。

`native/CMakeLists.txt` 通过 `LP_FFMPEG_ROOT` / `LP_SMB2_ROOT` 找到它们；
Android 由 Gradle 传参，Apple 由 Xcode 传参。

## 0.5 Windows（Zig，一条命令；本机已实测）

不需要 Visual Studio 或 MSYS2。`tool/fetch_deps.py` 下载固定版本的工具与依赖到 `.tools/`，
`scripts/build_windows.ps1` 负责编译、链接并复制运行时 DLL：

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Clean -RunSmoke
```

实测版本与产物（Windows 10 x64）：

|组件|版本 / 说明|
|-|-|
|Zig|0.13.0（clang 18 + mingw-w64 libc + lld）|
|FFmpeg|官方 Windows 共享构建 `N-127650`（libavutil 61，mingw 版，带 `lib*.dll.a`）|
|libsmb2|v4.0.0 源码，48 个文件全部编过并归档为 `libsmb2.a`|
|产物|`build/win-x64/{lanplayer.dll, lp_smoke_test.exe}` + FFmpeg DLL|

三条与平台相关的适配（都在仓库里，不需要改上游）：

1. `native/src/platform/desktop/win32_pthread.h` —— Zig 的 mingw 不带 pthread，用
SRWLOCK / CONDITION_VARIABLE / CreateThread 实现内核用到的线程原语。
2. `native/platform/win32/smb2/` —— libsmb2 的 Windows 支持针对 MSVC 写的，这里补了
`sys/socket.h`、`poll.h`、`arpa/inet.h`、`netinet/in.h`、`netdb.h`、`asprintf.h` 与
`win32_compat.h`（`random`/`getlogin_r` 等）。注意上游 `include/msvc/sys/socket.h`
用裸 `inline` 定义 `close/readv/writev`，在 GCC/Clang 下会在每个目标文件里生成外部
符号并导致重复定义，因此这里用 `lp_win_*` + 宏替代。
3. `LP_HAVE_SMB2` —— 没有 libsmb2 时 `smb.c` 编成空翻译单元，运行时把 `smb` 报为不支持的
协议，其余功能不受影响（CI 的 Linux job 就是这样跑的）。

自检输出应为：

```
abi=1
schemes=\["smb","file","http","https"]
no media given: library smoke test passed
```

## 1\. FFmpeg（必需组件）

两个脚本把下面的步骤都自动化了，推荐直接用：

```bash
ANDROID_NDK_HOME=\~/android-ndk-r26 ./scripts/build_android_deps.sh
./scripts/build_apple_deps.sh                 # 默认只做 macosx 切片
SLICES=iphoneos ./scripts/build_apple_deps.sh # 要编 iOS App 时再跑一次
```

脚本产物直接落在 `native/third_party/`，布局与第 0 节一致。下面手写步骤便于排错。

需要：`avformat avcodec avutil swresample swscale avfilter`。
**不要** `--disable-everything` 那种极限裁剪，至少保留：

```
--enable-protocol=file,http,https,tcp,tls
--enable-demuxer=matroska,mov,avi,mpegts,flv,mp3,aac,flac,wav,ogg,ass,srt,webvtt
--enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,aac,mp3,ac3,eac3,dts,flac,opus,vorbis,ass,subrip,webvtt
--enable-parser=h264,hevc,vp9,av1,mpegaudio,aac
--enable-filter=atempo,yadif,scale,format,aresample
--enable-swscale --enable-swresample
```

### Android

```bash
export NDK=$ANDROID_NDK_HOME
export API=26
for ABI in arm64-v8a armeabi-v7a; do
  case $ABI in
    arm64-v8a)   ARCH=arm64;   TRIPLE=aarch64-linux-android;;
    armeabi-v7a) ARCH=arm;     TRIPLE=armv7a-linux-androideabi;;
  esac
  ./configure \
    --target-os=android --arch=$ARCH --cpu=$ARCH \
    --enable-cross-compile --sysroot=$NDK/toolchains/llvm/prebuilt/*/sysroot \
    --cc=$NDK/toolchains/llvm/prebuilt/*/bin/$TRIPLE$API-clang \
    --cxx=$NDK/toolchains/llvm/prebuilt/*/bin/$TRIPLE$API-clang++ \
    --ar=$NDK/toolchains/llvm/prebuilt/*/bin/llvm-ar \
    --nm=$NDK/toolchains/llvm/prebuilt/*/bin/llvm-nm \
    --strip=$NDK/toolchains/llvm/prebuilt/*/bin/llvm-strip \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --enable-jni --enable-mediacodec --enable-videotoolbox=no \
    --enable-small
  make -j$(nproc) && make install prefix=../out/$ABI
done
```

> `--enable-mediacodec` 只影响 FFmpeg 自带的 hwaccel；本项目自己实现 MediaCodec 零拷贝
> 路径，所以这个开关是“备用”，保持打开无害。

### iOS / macOS

用仓库自带的脚本或手动：

```bash
./configure --prefix=/tmp/ff/apple --enable-cross-compile \
  --target-os=darwin --arch=arm64 \
  --cc="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0" \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-static --disable-shared --disable-programs --disable-doc
```

需要为 `iphoneos`（arm64）、`iphonesimulator`（arm64/x86_64）、`macosx` 各编一份，
最后 `lipo` 合并模拟器两个架构。`--enable-videotoolbox` 提供 `h264_videotoolbox`
等解码器，但**本项目使用的是直接调用 VTDecompressionSession 的路径**
（`platform/apple/videotoolbox_decoder.c`），FFmpeg 只需要负责解封装与音频。

## 2\. libsmb2

```bash
git clone https://github.com/sahlberg/libsmb2
cd libsmb2
# Android：用 CMake toolchain file
cmake -B build-android -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
      -DCMAKE_INSTALL_PREFIX=../out/android
cmake --build build-android -j && cmake --install build-android
# Apple：静态库
cmake -B build-apple -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=../out/apple
cmake --build build-apple -j && cmake --install build-apple
```

要求 libsmb2 **≥ 4.0**（用到 `smb2_stat_64`、`smb2_lseek`、目录接口）。
若要在 SMB 层做断线重连，可在 `smb.c` 里调用 `smb2_set_autoreconnect(ctx, 1)`（4.1+）。

## 3\. Android

```bash
cd app
flutter create --platforms=android,ios,macos .   # 只生成脚手架，不覆盖已有文件
flutter pub get
flutter build apk --release
```

关键配置（已提供）：

* `android/app/build.gradle.kts`：`minSdk 26`（AAudio）、`abiFilters arm64-v8a/armeabi-v7a`、
`externalNativeBuild` 指向 `src/main/cpp/CMakeLists.txt`，并把
`LP_FFMPEG_ROOT` / `LP_SMB2_ROOT` 传给 CMake。
* `android/app/src/main/cpp/CMakeLists.txt`：`add_subdirectory(native)`。
* `AndroidManifest.xml`：网络与媒体读权限、`usesCleartextTraffic`。
* `MainActivity.kt` + `native/.../jni_bridge.c`：SurfaceTexture → ANativeWindow 桥。

产物：`liblanplayer.so`（含 JNI 符号）+ 随包打入的 FFmpeg `.so`。

## 4\. iOS / iPadOS / macOS

Apple 平台没有 CMake，也不用 MSBuild。整条链路是：
**先在 Mac 上把 FFmpeg / libsmb2 / C 内核编成静态库，再由 CocoaPods 把它们链进 Runner。**

### 4.1 准备（只需一次）

按顺序装，每一步都有坑（下面这些是在一台 Apple Silicon Mac 上实际踩出来的）：

```bash
# 1) Xcode（不是只有命令行工具）
#    flutter build macos 需要完整 Xcode：xcodebuild -version 必须能打印版本，
#    只有 Command Line Tools 时会在构建早期报 "xcodebuild: error: ... requires Xcode"。
xcode-select --install          # 先把命令行工具装上
#    然后从 App Store 装 Xcode，装完执行：
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept

# 2) Homebrew（如果还没有）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3) CocoaPods：不要用 sudo gem install
#    macOS 自带的 Ruby 2.6 的 gem 目录是 /Library/Ruby/Gems/2.6.0，没有写权限，
#    sudo gem install cocoapods 会直接 "You don't have write permissions"。
brew install cocoapods
pod --version                   # 1.17.x

# 4) cmake：libsmb2 只能用 CMake 编
brew install cmake
cmake --version                 # 4.x，脚本已用 CMAKE_POLICY_VERSION_MINIMUM 兼容

# 5) Flutter：3.27.x（Apple 侧只需要 flutter 命令与 Dart SDK）
#    注意：装 Xcode / Homebrew / CocoaPods 都【不会】顺带装 Flutter。
#    没装时 `cd app && flutter build macos` 只会得到 `zsh: command not found: flutter`。
#
#    国内网络强烈建议【不要】用 `brew install --cask flutter`：
#    cask 只是去 storage.googleapis.com 下一个 1.3 GB 的 zip，Homebrew 本身不走镜像，
#    实测经常只有几十 KB/s。改成手动从 CFUG 镜像下载同一个包，再处理"隔离属性"：
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
mkdir -p ~/development && cd ~/development
#    Apple Silicon 用 arm64 包（1.49 GB），Intel 用不带 arm64 的那个（1.49 GB）：
curl -L -o flutter.zip \
  https://storage.flutter-io.cn/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.27.4-stable.zip
unzip -q flutter.zip && rm flutter.zip
#    这一步可以【跳过】。从镜像 curl 下来的 zip 通常不带 quarantine 属性，
#    而且 SDK 的 bin/cache 里有些产物是只读/签名过的，xattr 会刷一屏
#    "Permission denied"，那是正常的，不影响 flutter 运行。
#    只有在真的弹 "flutter 已损坏" 时才需要跑（见 4.8 报错表）。
#    xattr -dr com.apple.quarantine ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.zshrc
echo 'export PUB_HOSTED_URL=https://pub.flutter-io.cn' >> ~/.zshrc
echo 'export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn' >> ~/.zshrc
source ~/.zshrc

#    下面这条第一次会打印 "Building flutter tool..." 并编 ~3 分钟（只此一次）。
#    期间终端没有任何输出是正常的，不是卡死；判断卡死的方法见本节末尾的"卡住时怎么排查"。
flutter --version --no-version-check
flutter precache --macos         # 从镜像拉 macOS 引擎产物（含 Dart SDK，约 450 MB，走镜像约 1~3 分钟）

# 6) 用 flutter doctor 一次性确认 Xcode / CocoaPods / Flutter 三者都认到了
flutter doctor -v
#    要看到 [✓] Flutter、[✓] Xcode (含 CocoaPods installed)、[✓] Connected device
#    出现 [!] Xcode ... CocoaPods not installed 就是第 3 步没生效；
#    出现 [!] Xcode ... requires Xcode 就是还停在 Command Line Tools。
```

> 手动解压的 SDK 自带 Dart SDK，不需要另装 Dart。Apple 侧用不到 Android 那部分，
> 忽略 `flutter doctor` 里 Android 那一行即可。
>
> 镜像只影响**下载**，不影响代码：`flutter/generated_*.dart`、`pubspec.lock` 里的内容
> 与用官方源装出来的完全一样（`flutter-io.cn` 是按原样镜像 `storage.googleapis.com` 的）。
> 想验证镜像对不对，比对一下 zip 的 sha256：3.27.4 arm64 包的官方值见
> <https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json>，
> 走镜像下载的应当与之一致（不一致说明下载损坏，删掉重下）。
>
> 如果镜像也慢，还有两个备用源（变量值不同，用法一样）：
> 上海交大 `PUB_HOSTED_URL=https://mirror.sjtu.edu.cn/dart-pub` +
> `FLUTTER_STORAGE_BASE_URL=https://mirror.sjtu.edu.cn`；清华 TUNA
> `PUB_HOSTED_URL=https://mirrors.tuna.tsinghua.edu.cn/dart-pub` +
> `FLUTTER_STORAGE_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/flutter`。

#### 卡住时怎么排查

`flutter` 会先跑 `bin/flutter` → `bin/internal/shared.sh`，判断 `bin/cache/flutter_tools.snapshot`
是否与 SDK 版本匹配；不匹配就**编一遍 flutter tool**。这一步要 `pub upgrade`，
终端会一直停在 `Building flutter tool...` 上、**没有任何进度输出**，看起来和卡死一样。
在本机（Windows，`--version` 全程）实测：冷启动 179 s（约 3 分钟），其中 `pub upgrade`
只占十几秒；之后有缓存时是 0.45 s。

另外两条同样会"像卡死"的路径（35 s 左右，看起来像死了）：

- `--version` 默认会做**版本检查**（每 3 天一次）：`git fetch` Flutter 官方仓库 + 访问
  `storage.googleapis.com`，国内很可能 35 s 超时。加 `--no-version-check` 直接跳过，
  或者 `export FLUTTER_SUPPRESS_ANALYTICS=true` 减少网络调用。
- `flutter precache` 从 `FLUTTER_STORAGE_BASE_URL` 下载引擎产物；没设镜像变量时连的是
  `storage.googleapis.com`，超时报 `Can not install platforms and resources: signal timed out`。

逐条排查：

```bash
# 1) 确认不是在编 tool：另开一个终端看有没有这些进程
ps aux | grep -E 'dart|gen_snapshot' | grep -v grep
#    有 -> 正在编，等到出现版本号即可；确实想重来就先 Ctrl-C，再
rm -rf ~/development/flutter/bin/cache/flutter_tools.snapshot   # 下次自动重编

# 2) 确认两个镜像变量在当前 shell 里真的生效了
echo $PUB_HOSTED_URL          # https://pub.flutter-io.cn
echo $FLUTTER_STORAGE_BASE_URL # https://storage.flutter-io.cn

# 3) 绕开版本检查，看能不能直接打印版本
flutter --version --no-version-check

# 4) 镜像是否真的通（必须 200，且不是 HTML 错误页）
curl -sI https://storage.flutter-io.cn/flutter_infra_release/releases/releases_macos.json | head -1

# 5) 再 precache；还报 timed out 就换备用镜像重试
flutter precache --macos
```

仓库克隆（GitHub 已关掉 HTTPS 密码认证，用 SSH）：

```bash
ssh-keygen -t ed25519 -C "you@mac"
# 把 ~/.ssh/id_ed25519.pub 贴到 GitHub → Settings → SSH and GPG keys
ssh -T git@github.com           # 看到 "Hi <user>! You've successfully authenticated"
git clone git@github.com:LXinH3RT/LanPlayer.git
cd LanPlayer
chmod +x scripts/*.sh           # 仓库里 .sh 是 100644，不 chmod 会 permission denied
```

CocoaPods 首次跑 `pod install` 要拉 Specs 仓库（约 250 MB，`~/.cocoapods/repos/master`），
慢的话可以先 `git clone --depth 1 https://github.com/CocoaPods/Specs.git ~/.cocoapods/repos/master`。

### 4.2 编静态库

```bash
cd /path/to/LanPlayer
./scripts/build_apple_deps.sh                 # 默认只做 macosx（桌面构建用这个）
SLICES=iphoneos ./scripts/build_apple_deps.sh # 做 iOS 真机切片
SLICES=iphonesimulator ./scripts/build_apple_deps.sh  # 做 iOS 模拟器切片
ARCHS="arm64 x86_64" ./scripts/build_apple_deps.sh   # Intel Mac 再加 x86_64
```

> **一次只能做一个平台族，但三个族可以共存。** Apple silicon 上 `iphoneos` /
> `iphonesimulator` / `macosx` 都是 arm64，`lipo` 不允许把两个同架构的切片塞进
> 同一个 fat 归档（`have the same architectures (arm64) and can't be in the same
> fat output file`），所以一次运行的 `SLICES` 不能跨族——脚本在开头就检查并直接
> 报错退出（不会白编二十分钟）。
> 每个族写**各自的目录** `native/third_party/<lib>/apple/<family>/lib`，所以
> macOS 与 iOS 的归档可以同时存在，先做 macOS 再做 iOS 不会把前者覆盖掉。
> 老路径 `apple/lib` 仍会被填一份（附带 `.family` 标记），只作为「这个克隆只跑过
> 一族构建」时的兜底。默认值从「三切片」改成 `macosx`：桌面构建只要 macOS 切片，
> 而 iOS 真机/模拟器需要时显式指定。FFmpeg 会按切片缓存，换目标只重编不同的那一个。

产出（每个平台族一套，全部是 universal 静态库，已按切片 `lipo` 合并）：

| 路径 | 内容 |
| --- | --- |
| `native/third_party/ffmpeg/apple/<family>/lib` | `libavformat.a` `libavcodec.a` `libavutil.a` `libswresample.a` `libswscale.a` `libavfilter.a` |
| `native/third_party/libsmb2/apple/<family>/lib` | `libsmb2.a` |
| `native/third_party/lanplayer/apple/<family>/lib` | `liblanplayer.a` ← **C 内核自己**（16 个 .c：核心 13 个 + `platform/apple` 3 个） |
| `native/third_party/*/apple/lib` | 最近一次构建那一族的副本（兜底，带 `.family` 标记） |

`<family>` 取 `macosx` / `iphoneos` / `iphonesimulator`。podspec 用 Xcode 的
`$(PLATFORM_NAME)` 自动选对目录，不需要在切换目标时改任何工程设置。

这一步会把 FFmpeg 6.1.1 与 libsmb2 v4.0.0 的源码下载到 `build/deps/`，编译十几分钟。
`native/third_party/` 已被 `.gitignore` 排除，不进版本库。

FFmpeg 编完会缓存（`build/deps/ff-<slice>/lib/libavcodec.a` 存在就跳过），
改脚本后重跑不会把十几分钟再花一遍；要强编 `FORCE=1 ./scripts/build_apple_deps.sh`。

脚本里针对 macOS 的两处必需开关（早期版本没有，会在 libsmb2 段失败）：

- `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE` / `..._OpenSSL=TRUE`：
  libsmb2 的 CMakeLists 无条件 `find_package(GSSAPI)` + `find_package(OpenSSL)`，
  macOS 自带 `libgssapi_krb5.tbd` 与 `gssapi/gssapi.h`，于是 `HAVE_LIBKRB5` 被定义，
  接着编 `lib/krb5-wrapper.c`——它用的 `gss_const_OID`、`gss_acquire_cred_with_password`、
  `gss_buffer_set_t`、`gss_set_neg_mechs`、`gss_inquire_sec_context_by_oid` 都是 MIT/Heimdal
  krb5 的扩展，Apple 的 GSS.framework 没有，Xcode 15 起隐式函数声明是硬错误，
  结果是 `17 warnings and 18 errors` 卡在 `krb5-wrapper.c.o`。
  我们只用 NTLM（用户名 + 密码），不需要 Kerberos，关掉即可。
  （**不要**加 `-DUSE_KRB5=OFF`——libsmb2 没有这个变量，CMake 只会打一句
  `Manually-specified variables were not used by the project: USE_KRB5`，等于没改。）
- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`：libsmb2 v4.0.0 的 `cmake_minimum_required(VERSION 3.2)`，
  而 Homebrew 装的 CMake 4.x 已删除 `< 3.5` 兼容性，配置阶段直接报
  `Compatibility with CMake < 3.5 has been removed`。

### 4.3 接进 Flutter 工程

这一步**不需要打开 Xcode 点任何东西**，仓库里已经配好了：

- `packages/lanplayer_core/`：一个 `ffiPlugin: true` 的 Dart 空包，`ios/` 与 `macos/` 下各有一个
  `lanplayer_core.podspec`。podspec 做三件事——把 `native/include` 加进
  `HEADER_SEARCH_PATHS`、把三个库目录加进 `LIBRARY_SEARCH_PATHS`、把
  `-llanplayer -lavformat -lavcodec -lswresample -lavfilter -lswscale -lavutil -lsmb2`
  加进 `OTHER_LDFLAGS`，并链接 `VideoToolbox CoreMedia CoreVideo AudioToolbox
  CoreFoundation Security` 与 `z bz2 lzma iconv`。
- `app/pubspec.yaml` 里已声明 `lanplayer_core: {path: ../packages/lanplayer_core}`。
- `app/ios/Podfile` 与 `app/macos/Podfile` 已存在（`platform :ios, '15.0'` / `platform :osx, '12.0'`，
  与 `build_apple_deps.sh` 的 `MIN_IOS`/`MIN_MACOS` 对齐），里面没有手写 `pod` 行——
  Flutter 会读 `.flutter-plugins-dependencies`，自动把 `lanplayer_core` 装上。
  iOS 侧 `post_install` 会把**每个 pod**（以及 `Pods.xcodeproj` 的项目级）的
  `IPHONEOS_DEPLOYMENT_TARGET` 统一抬到 15.0：第三方插件的 podspec 自带更低
  数字（`path_provider_foundation` 写的是 12.0），Xcode 27 的受支持下限是 15.0，
  低于它直接报 `Target Integrity (Xcode)` 拒绝构建。
  macOS 侧 `post_install` 里还会把**每个 pod**（以及 `Pods.xcodeproj` 的项目级）
  的 `MACOSX_DEPLOYMENT_TARGET` 统一抬到 12.0：第三方插件的 podspec 自带更低
  数字（`path_provider_foundation` 写的是 10.14），Xcode 26 不支持低于 12.0。
  `app/macos/Runner/Configs/AppInfo.xcconfig` 也钉了 `MACOSX_DEPLOYMENT_TARGET = 12.0`
  作为 target 级保险。
- 四个 xcconfig（`app/ios/Flutter/{Debug,Release}.xcconfig`、
  `app/macos/Flutter/Flutter-{Debug,Release}.xcconfig`）第一行是
  `#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.<mode>.xcconfig"`，
  这样还没跑过 `pod install` 时也不会配置失败。
- `SWIFT_OBJC_BRIDGING_HEADER` 已写进两个工程：iOS 侧本来就有，macOS 侧这次补上
  （`Runner/Runner-Bridging-Header.h`），Swift 才能看到 `lp_player_*`。

```bash
cd app
flutter pub get
flutter build macos --release     # 或 flutter build ios --release --no-codesign
```

如果报 `library not found for -llanplayer`，说明 4.2 没跑或没成功；报
`building for iOS 14.0, but linking in object file built for iOS 15.0`，说明
依赖是用更高的 `MIN_IOS` 编的，把工程目标同步调高（或重跑 4.2）。

### 4.4 桌面纹理与音频

- `app/macos/Runner/MainFlutterWindow.swift`：注册 `lanplayer/video` 通道，
  `PlayerTexture` 从内核拉 `CVPixelBuffer` 交给 Flutter 引擎（BGRA，带图形字幕叠加）。
  `setFullscreen` 返回 `false`，让 Dart 回落到 Flutter 自己的全屏（macOS 的全屏是系统级的，
  窗口有菜单栏）。
- `app/ios/Runner/AppDelegate.swift`：同一套通道的 iOS 版。
- 音频走 `native/src/platform/apple/coreaudio_sink.c`（AudioQueue，3×20 ms）。
- 视频解码走 `native/src/platform/apple/videotoolbox_decoder.c`。

### 4.5 权限

`app/ios/Runner/Info.plist` 已含 `NSLocalNetworkUsageDescription`、
`NSBonjourServices`(`_smb._tcp`)、`UIBackgroundModes=audio`、`UIFileSharingEnabled`、
四个方向（iPad 含 UpsideDown）。
`app/macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements` 都已含
`com.apple.security.network.client`（**没有它沙盒会拦掉 445 出站**）与
`com.apple.security.files.user-selected.read-only`（播放本地视频用）。

### 4.6 真机/模拟器

```bash
flutter devices
flutter run -d <device-id>            # 调试
flutter build ipa --release           # 打包（需要签名）
```

iPad 与 iPhone 是同一个 iOS 包；`TARGETED_DEVICE_FAMILY = "1,2"` 已包含 iPad。
模拟器不能测 SMB 的真实吞吐，但能测 UI、字幕、界面交互。

**iOS 侧已经实测跑通的部分**（iPad 模拟器，iPadOS 27.1）：
VideoToolbox 硬解、AudioQueue 48 kHz 立体声、外挂 SRT 字幕、纹理上屏。

#### 4.6.1 真机：Xcode 27 里找不到「Devices and Simulators」

Xcode 27 把设备管理窗口拆成了**独立 app**：`Device Hub`，位于

```
/Applications/Xcode.app/Contents/Applications/DeviceHub.app
```

（bundle id `com.apple.dt.Devices`，版本 27.1）。所以 `Window` 菜单里已经没有
「Devices and Simulators」这一项，找它必然找不到。打开方式：

```bash
open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app
```

命令行等价物（不需要 GUI）是：

```bash
xcrun devicectl list devices                        # 看设备列表
xcrun devicectl device info details --device <UDID> # 看配对/开发者模式
```

`xcrun xcdevice list` 在 Xcode 27 上**只列模拟器**，看不到实体设备——它没有坏，
只是不再负责实体设备枚举。

#### 4.6.2 USB 插上了但设备不出现

`system_profiler SPUSBDataType` 数不出 iPad、`devicectl list devices` 也只有模拟器，
但 `ioreg -p IOUSB -w0 -l` 里设备**其实已经在 USB 总线上**（`idVendor = 1452`、
`"USB Product Name" = "iPad"`）。这种「在总线上但不枚举」几乎都是同一件事：

- **iPad 锁屏了**。锁屏时不启用暴露 `com.apple.mobiledevice` 的 data 配置，
  也不会弹「要信任这台电脑吗」。

解锁屏幕后再看，`devicectl` 立刻就能列出。判断依据：

```bash
$HOME/.lpvenv/bin/pymobiledevice3 usbmux list   # 空数组 [] = 没枚举到
```

#### 4.6.3 无线调试默认是关的

`flutter devices` 只会看到 USB 上的设备。无线调试要先打开一次（之后一直生效）：

```bash
pymobiledevice3 lockdown wifi-connections on
pymobiledevice3 lockdown wifi-connections     # 确认 EnableWifiConnections: true
```

打开后 `usbmux list` 会出现两条同一 UDID 的记录，`ConnectionType` 分别是
`Network` 与 `USB`。注意 `flutter devices` 末尾仍会打印
`No wireless devices were found.`——那是它在找**只**在网络上、没插线的设备，
不代表无线没通。

#### 4.6.4 真机安装：`flutter install` 在 Xcode 27 上不可用

Xcode 27 删掉了旧的 MobileDevice 栈，`flutter install` / `flutter run` 装真机会失败。
能用的路径是 `devicectl`：

```bash
TEAM_ID=ABCD123456 ./scripts/ios_device_install.sh
```

这个脚本做四件事：把 `DEVELOPMENT_TEAM` 写进 `app/ios/Runner.xcodeproj/project.pbxproj`
（每个 `PRODUCT_BUNDLE_IDENTIFIER` 的 target 都要有，否则报
`Signing for "Runner" requires a development team`）→ `flutter build ios --release`
→ `xcrun devicectl device install app` → `xcrun devicectl device process launch`。

真机静态库要先单编一次（默认 `ARCHS=arm64`，与 iPad 一致）：

```bash
SLICES=iphoneos ./scripts/build_apple_deps.sh
```

产出在 `native/third_party/*/apple/iphoneos/lib/`，与 macOS / iOS 模拟器两族并存
（见 4.2）。`flutter build ios --release --no-codesign` 可以在没登录 Apple ID 的
机器上先验证「代码本身能不能为 arm64 设备编过」。

真机装机的三个必踩点（都已实测，见 `docs/verification.md` 3.27）：

1. **Team ID 从证书里读，不用等 Xcode 界面**：

   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject
   # subject= /UID=.../CN=Apple Development: .../OU=<TEAM_ID>/O=.../C=US
   #                                               ^^ Team ID
   ```

2. **SSH 非交互会话签不了名**。`codesign` 报
   `Failed to codesign .../Flutter.framework/Flutter with identity ...`，
   根因是 `security show-keychain-info` 返回
   `User interaction is not allowed.`。若 login keychain 无密码，先解一次锁：

   ```bash
   security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db
   ```

   解锁后同一会话里 `codesign` 立即 rc=0。脚本本身不含这一步（不宜把空密码写死）。

3. **卸载重装会重置「开发者信任」**。profile 仍然 `Valid`，但启动报
   `error 10002 ... its profile has not been explicitly trusted by the user`。
   iPad 上需要在 `设置 → 通用 → VPN与设备管理` 手动点一次信任；
   点完后 `devicectl device process launch` 立刻成功。**没有命令行替代方案。**

信任恢复之后，`devicectl device process launch --console` 就能直接读到内核日志
（内核走 `fprintf(stderr, ...)`），不需要 `flutter run`：

```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> dev.lanplayer.lanplayer
# [LanPlayer I videotoolbox] session ready 1920x820 (h264)
# [LanPlayer I video] hardware decode videotoolbox 1920x820
# [LanPlayer I audioqueue] started 48000Hz x2
```

真机截图用 `devicectl`（`simctl io` 只对模拟器有效）：

```bash
xcrun devicectl device capture screenshot --device <UDID> --destination out.png
# Dimensions: 2746x1908 pixels
```

模拟器上的验证钩子要注意：iOS 的 app 由 launchd 拉起，Dart 侧的
`Platform.environment` **永远是空表**，`SIMCTL_CHILD_LANPLAYER_OPEN=...`
虽然确实进了进程环境（`ps eww -p <pid>` 能看到），但 Dart 读不到。
所以 iOS 上要改用编译期注入：

```bash
cd app
flutter build ios --simulator --debug \
  --dart-define=LANPLAYER_OPEN=/Users/me/lptest/clip.mp4 \
  --dart-define=LANPLAYER_STATE_DIR=/Users/me/lptest/state
xcrun simctl install <dev> build/ios/iphonesimulator/Runner.app
xcrun simctl launch --console-pty <dev> dev.lanplayer.lanplayer   # 内核日志走这里
```

`--console-pty` 是关键：内核的 `[LanPlayer I ...]` 日志只出现在 app 的
stdout/stderr，`xcrun simctl spawn <dev> log show` 只能看到 `flutter:` 那些。
另外模拟器截图是可用的（`xcrun simctl io <dev> screenshot --type=png out.png`），
这点和 macOS 桌面端相反。

### 4.7 iOS 上会遇到的错误（按出现顺序）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动即 SIGTRAP，日志里有 `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` | iOS 26/27 SDK 要求 app 采用 UIScene 生命周期 | 已修：`Info.plist` 声明 `UIApplicationSceneManifest` 并去掉 `UIMainStoryboardFile`，`AppDelegate` 自己持有 `FlutterEngine`，由 `SceneDelegate` 建窗口。更新仓库即可 |
| 一打开视频就 SIGABRT，栈顶 `-[FlutterEngine registrarForPlugin:]` + `NSAssertionHandler` | `registrarForPlugin:` 对同名插件只能调一次，第二次直接 abort | 已修：`AppDelegate` 在 `attach()` 里取一次 `registrar` / `textures` 缓存复用。更新仓库即可 |
| `SIMCTL_CHILD_LANPLAYER_OPEN` 设了但 app 不自动打开视频 | iOS 上 Dart 的 `Platform.environment` 是空表 | 改用 `--dart-define=LANPLAYER_OPEN=...`（见 4.6） |
| `Target debug_unpack_ios failed: Binary .../Flutter.framework/Flutter does not contain architectures "arm64 x86_64"` | Mac 上 Flutter SDK 的 iOS 模拟器切片架构与工程 `ARCHS` 不匹配 | 已修：`app/ios/Flutter/*.xcconfig` 收紧到 `ARCHS = arm64` |
| `error: The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 13.0, but the range ... is 15.0 to 27.1.x` | Xcode 27 把 iOS 最低部署目标抬到 15.0 | 已修：`Podfile` / `project.pbxproj` / `AppFrameworkInfo.plist` / podspec 四处统一到 15.0，`post_install` 再兜一层。更新仓库即可 |
| `vf_scale_vt.c: 'VTPixelTransferSessionCreate' is only available on iOS 16.0 or newer` | `--enable-videotoolbox` 会自动拉进 `scale_vt` 滤镜，它用的 API 在 iOS 16 才有，FFmpeg 6.1.1 没加可用性保护 | 已修：`build_apple_deps.sh` 加 `-Wno-error=unguarded-availability-new` 并显式裁剪滤镜列表。更新仓库即可 |
| `sed: 1: "s\|(PRODUCT_BUNDLE_IDENT ...": unescaped newline inside substitute pattern` | BSD sed 的替换式里不能有真正的换行，`ios_device_install.sh` 原先这么插 `DEVELOPMENT_TEAM` | 已修：改用 `awk` 匹配 `PRODUCT_BUNDLE_IDENTIFIER` 后按原缩进追加一行。更新仓库即可 |
| `Failed to codesign .../Flutter.framework/Flutter with identity 7D41...`（`security show-keychain-info` 报 `User interaction is not allowed.`） | SSH 非交互会话没有钥匙串访问权 | 先 `security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db`（见 4.6.4） |
| `error 10002 ... its profile has not been explicitly trusted by the user` | 卸载重装后开发证书信任被重置；profile 仍报 `Valid` | iPad 上 `设置 → 通用 → VPN与设备管理` 手动点一次信任（见 4.6.4） |
| 真机 USB 插上但 `devicectl list devices` 只看到模拟器 | iPad 锁屏时不会启用暴露 `com.apple.mobiledevice` 的 data 配置，也弹不出「信任这台电脑」 | 解锁 iPad 后重试；`ioreg -p IOUSB` 里能看到设备说明线没问题（见 4.6.2） |
| `error: Signing for "Runner" requires a development team.` | 工程里没有 `DEVELOPMENT_TEAM`，且 Xcode 里没登录 Apple ID（`security find-identity -v -p codesigning` 返回 0 valid identities） | Xcode → Settings → Accounts 登录 Apple ID 生成 Apple Development 证书，再 `TEAM_ID=<10 位> ./scripts/ios_device_install.sh`（见 4.6.4） |
| `Window` 菜单里没有「Devices and Simulators」 | Xcode 27 把它拆成独立 app `Device Hub` | `open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app`（见 4.6.1） |

### 4.8 macOS 上首次构建会遇到的错误（按出现顺序）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `zsh: permission denied: ./scripts/build_apple_deps.sh` | 仓库里的 `.sh` 曾以 `100644` 提交，执行位丢了 | 已修：两个 `.sh` 在 git 里改成 `100755`；旧克隆上直接 `bash scripts/build_apple_deps.sh` 也行 |
| `error: SLICES spans more than one platform family` | 一次跑了 `iphoneos` + `iphonesimulator` + `macosx`，三者都是 arm64，`lipo` 不允许多个同架构切片进同一个 fat 归档 | 一次只做一个族：`SLICES=macosx`（默认）/ `SLICES=iphoneos` / `SLICES=iphonesimulator`。三个族各写自己的目录，可以先后都做，互不覆盖 |
| `zsh: command not found: flutter` | 装 Xcode / Homebrew / CocoaPods 都不会顺手装 Flutter | 按 4.1 第 5 步从镜像装，再确认新终端里 `flutter --version` 可用 |
| `flutter --version` 停在 `Building flutter tool...` 不动 | 首次运行要编 flutter tool（`pub upgrade` + 编快照），这期间没有任何进度输出 | 正常，本机实测 179 s；另开终端 `ps aux \| grep dart` 能看到进程就是在干活 |
| `flutter --version` 卡 30 s 以上才回 | 默认每 3 天做一次版本检查（`git fetch` 官方仓库 + 访问 `storage.googleapis.com`），国内常 35 s 超时 | `flutter --version --no-version-check`，或 export `FLUTTER_SUPPRESS_ANALYTICS=true` |
| `flutter precache` 卡住，最后报 `Can not install platforms and resources: signal timed out` | 没有走镜像，直连 `storage.googleapis.com` | 先 `echo $FLUTTER_STORAGE_BASE_URL`，应为 `https://storage.flutter-io.cn`；再 `flutter precache -v --macos` 看它实际在拉哪个 URL |
| `flutter doctor` 里 Flutter 那行报 `Downloaded executables cannot execute on host` / `Flutter requires the Rosetta translation environment on ARM Macs` | 引擎产物里混进了 x86_64 的 `gen_snapshot`，Apple Silicon 上没装 Rosetta 就跑不了 | `sudo softwareupdate --install-rosetta --agree-to-license`；装完再 `flutter doctor` 应转成 `[✓]`。**这一步不做，`flutter build macos` 会在 AOT 那步直接死掉** |
| `[!] Xcode - develop for iOS and macOS: Xcode installation is incomplete; a full installation is necessary` | 只装了 Command Line Tools，或 Xcode 下完没跑首次启动 | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch`（还要 `sudo xcodebuild -license accept`） |
| `flutter build macos` 报 `Unable to find a device matching { platform:macOS, arch:arm64 }` | Flutter 3.27 在 macOS 26 / Xcode 26 上认不出 macOS 设备（[flutter#183353](https://github.com/flutter/flutter/issues/183353)） | 换成 Xcode 版本识别的老写法：`flutter build macos --release` 走不到这里时，改用 `flutter run -d macos` 先确认；必要时把 Flutter 升到能识别该 Xcode 的版本 |
| `cmake: command not found` | macOS 不带 cmake | `brew install cmake` |
| `Compatibility with CMake < 3.5 has been removed` | libsmb2 要求 3.2，CMake 4.x 不支持 | 脚本已传 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`，更新仓库即可 |
| `krb5-wrapper.c: unknown type name 'gss_const_OID'` 等 18 个 error | macOS 有 GSSAPI 头但缺 MIT/Heimdal 扩展 | 脚本已传 `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE`，更新仓库即可 |
| `You don't have write permissions for /Library/Ruby/Gems/2.6.0` | 系统 ruby 的 gem 目录只读 | 不要 `sudo gem install`，用 `brew install cocoapods` |
| `xcodebuild: error: ... requires Xcode, but active developer directory ... is a command line tools instance` | 只装了 Command Line Tools | 装完整 Xcode 后 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `Failed to load 'lanplayer_core' podspec: undefined method 'lanplayer_repo_root' for module Pod` | CocoaPods 1.16 起把 podspec 放在 `module Pod` 作用域里 eval，podspec 顶层的 `def` 会变成 `Pod` 的实例方法，裸调用就报 undefined method | 已修：`lanplayer_core.podspec` 不再定义方法，改成 `LP_ROOT = begin … end` 按 `native/src/core/player.c` 标记向上找仓库根。更新仓库即可 |
| `[!] The 'lanplayer_core' pod failed to validate due to 1 error: - ERROR \| File Patterns: File patterns must be relative and cannot start with a slash (preserve_paths)` | podspec 里用 `preserve_paths` 声明了 `native/` 下的头文件与 `.a`，但 CocoaPods 校验要求每条 pattern 都是相对 pod 目录的路径，绝对路径直接判死，`pod install` 还没开始就退出 | 已修：删掉 `preserve_paths`（头文件与 `.a` 在 pod 目录之外，CocoaPods 本来也不会删；链接靠 `user_target_xcconfig` 的 `LIBRARY_SEARCH_PATHS` / `HEADER_SEARCH_PATHS`）。更新仓库即可 |
| `WARN \| [OSX] keys: Missing primary key for \`source\` attribute. The acceptable ones are: git, hg, http, svn` | `s.source = { :path => '.' }` 没有主键；本地 path 依赖时 CocoaPods 只当警告，但它和上面那条 ERROR 一起出现时容易看漏 | 已修：`s.source` 改成 `{ :git => '…LanPlayer.git', :tag => s.version.to_s }`（这个 pod 实际由 `app/*/Podfile` 的 path 依赖引入，source 只为过校验） |
| `library not found for -llanplayer` | 4.2 没成功（`native/third_party/lanplayer/apple/<family>/lib` 不存在） | 重跑对应族的 `SLICES=macosx ./scripts/build_apple_deps.sh` |
| `ld: building for 'macOS', but linking in object file (…liblanplayer.a[2](lp_str.o)) built for 'iOS-simulator'` | 旧版脚本把三个族的归档都写进同一个 `native/third_party/*/apple/lib`，做 iOS 时把 macOS 那份覆盖了 | 已修：脚本按族写 `apple/<family>/lib`，podspec 用 `$(PLATFORM_NAME)` 选目录。更新仓库后重跑一次 `SLICES=macosx ./scripts/build_apple_deps.sh`（不必删旧的，新目录写进去就生效） |
| `building for macOS 12.0, but linking in object file built for macOS 14.0` | 依赖用了更高的部署目标 | `MIN_MACOS=12.0` 重编，或把 `app/macos/Podfile` 与工程目标一起调高 |
| `error: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to 10.14/11.0, but the range of supported deployment target versions is 12.0 to 27.0.x` | Xcode 26（macOS SDK 27）把最低部署目标抬到了 12.0；第三方 pod（如 `path_provider_foundation` 10.14）与旧工程设置（11.0）都被判非法 | 已修：`app/macos/Podfile` 的 `platform` 改 12.0，并在 `post_install` 里把每个 pod 的 `MACOSX_DEPLOYMENT_TARGET` 统一设为 12.0；`Runner.xcodeproj` 的三处 11.0 也已改成 12.0。更新仓库后 `pod install` 会自动重生成 |
| `brew install --cask flutter` 慢到只有几十 KB/s | cask 直接去 `storage.googleapis.com` 拉 1.3 GB，Homebrew 本身不走国内镜像 | 按 4.1 第 5 步手动从 `storage.flutter-io.cn` 下载解压 |
| `xattr -dr com.apple.quarantine` 输出一屏 `Permission denied` | SDK 的 `bin/cache/artifacts` 与 `.git/objects` 里有只读/已签名文件，xattr 改不动 | **正常现象，忽略即可**。这条命令本来就可以跳过；只有真弹 "flutter 已损坏" 时才需要执行 |
| `"flutter" 已损坏，无法打开` / Gatekeeper 拦截 | 手动解压的 SDK 带 quarantine 属性 | `xattr -dr com.apple.quarantine ~/development/flutter`（有 Permission denied 不影响结果） |
| `flutter pub get` 卡在 pub.dev | 没设 `PUB_HOSTED_URL` | `export PUB_HOSTED_URL=https://pub.flutter-io.cn`（写进 `~/.zshrc` 一次性解决） |
| App 能开但连不上 SMB | macOS 沙盒拦 445 出站 | 确认 `Runner/*.entitlements` 里有 `com.apple.security.network.client` |

`pod install` 的顺序不要搞反：**先 `build_apple_deps.sh` 产出静态库，再 `flutter pub get`，
最后 `flutter build macos`**。`flutter build` 内部会自动跑 `pod install`；
单独手跑 `pod install` 必须先在 `app/` 下执行过一次 `flutter pub get`，
否则会报 `Flutter/Flutter-Generated.xcconfig must exist`。

## 5\. Flutter Windows 桌面端

桌面端由三块组成：Flutter 的 runner（`app/windows/`）、我方插件（`packages/lanplayer_video/`）、
以及带 Win32 输出适配的 `lanplayer.dll`。

**一条命令（本机实测，推荐）：**

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2 flutter dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.ps1 -Core -Clean
```

`scripts/build_windows_desktop.ps1` 做的事：

1. `scripts/fix_plugin_links.ps1` —— 在 `app/windows/flutter/ephemeral/.plugin_symlinks/`
   里给 `lanplayer_video`、`path_provider_windows` 建 **junction**（不是符号链接）；
2. `dart pub get`（环境变量重定向到 `.tools/`）；
3. VS 自带的 cmake 以 `-G "Visual Studio 18 2026"` 生成，MSBuild 编 Release；
4. `--target INSTALL` 把 `data/flutter_assets`、`icudtl.dat`、`flutter_windows.dll`
   放到 exe 旁，再复制 `lanplayer.dll` 与 7 个 FFmpeg DLL。

只想要内核时：`scripts\build_windows.ps1`（Zig，无需 VS）。

**官方 `flutter build windows` 路径**（本机已跑通，见下）：

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2 flutter dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Clean
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fix_plugin_links.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\patch_flutter_tools.ps1
cd app
flutter pub get
flutter build windows --release
powershell -NoProfile -ExecutionPolicy Bypass -File ..\scripts\build_windows.ps1 `
    -DeployTo build\windows\x64\runner\Release
```

本机装的是 **VS 18（2026）**，默认会失败在两处，上面的两条脚本各修一处：

* `flutter_tools/lib/src/windows/visual_studio.dart` 里 generator 是硬编码的
  `17 => 'Visual Studio 17 2022', _ => 'Visual Studio 16 2019'`，VS 18 会落到 `_` 分支，
  于是 `CMake Error ... Generator Visual Studio 16 2019 could not find any instance of
  Visual Studio`。`scripts\patch_flutter_tools.ps1` 从 `cmake --help` 读出 `Visual Studio
  18 2026` 并注入成显式分支，再重建 `flutter_tools.snapshot`（SDK 在 `.tools/` 里，
  属于工具缓存，不进版本库；脚本幂等，重复运行只会打印 already patched）。
* `flutter pub get` 要建符号链接，普通令牌没有 `SeCreateSymbolicLink`（`errno 1314`），
  而 junction 能被 `flutter_plugins.dart` 的 `if (link.existsSync()) continue;` 直接跳过，
  所以先用 `scripts\fix_plugin_links.ps1` 预建。

实测：`√ Built build\windows\x64\runner\Release\lanplayer.exe`，24 秒。**但
`flutter build windows` 不会部署 `lanplayer.dll` 与 7 个 FFmpeg DLL**，最后一步的
`-DeployTo` 必须执行，否则运行时报「找不到 FFmpeg」。

`scripts/build_windows_desktop.ps1` 是另一条独立通道（VS 自带 cmake + MSBuild），
不打补丁的机器上也能用，产物在 `app\windows\out\build\x64-VisualStudio182026\`。

要点：

* **插件不链接内核**：`lanplayer_video_plugin.dll` 运行时 `LoadLibrary` 找 `lanplayer.dll`
  （顺序：`LANPLAYER_CORE` 环境变量 → exe 同目录 → 当前目录），因此内核可以独立重编、替换。
* **纹理契约**：插件注册 `flutter::PixelBufferTexture`；内核视频线程回调里调
  `MarkTextureFrameAvailable`（文档保证线程安全），真正的 BGRA 拷贝发生在 raster 线程的
  `CopyPixelBuffer` 里。双缓冲 + `release_callback` 实现“引擎还在读的 buffer 不能被覆盖”，
  两块都占用时丢帧而不是阻塞解码。
* **Dart 侧不用改**：插件实现的就是 Android/iOS 用的同一个 `lanplayer/video` 通道
  （`createTexture` / `attachPlayer` / `resizeTexture` / `destroyTexture`），返回值里
  `window=0` 表示走纹理而非原生窗口。
* **状态目录**：`path_provider` 在 Windows 上没有原生实现时，插件内置了一个
  `plugins.flutter.io/path_provider` 兜底通道（`SHGetKnownFolderPath` + `GetFileVersionInfoW`
  取 `CompanyName`/`ProductName`），因此 `servers.json` 能落在
  `%APPDATA%\<Company>\<Product>\lanplayer`。可用 `LANPLAYER_STATE_DIR` 覆盖。
* `app/windows/flutter/generated_*.{cc,cmake}` 由脚本生成；生成的注册表按
  `pluginClass` 的 snake_case 去找头文件，所以插件头必须是
  `windows/include/lanplayer_video/lan_player_video_plugin.h`（注意 `lan_player` 这个拼写）。

## 6\. 桌面（CI / 调试用）

```bash
cmake -B build -DLP_FFMPEG_ROOT=native/third_party/ffmpeg/desktop \
      -DLP_SMB2_ROOT=native/third_party/libsmb2
cmake --build build -j
./build/lp_smoke_test                       # 只验证加载与 ABI
./build/lp_smoke_test /path/to/file.mkv 5   # 软解 5 秒并打印位置
```

桌面走 `platform/stub`：无窗口、无声音，但有真实的音频拉取线程，因此可以验证
解封装、解码、时钟、字幕时序。Windows 上更完整的是 `scripts/build_windows.ps1` 产物
（`lanplayer.dll` 带 GDI/waveOut，`lanplayer_preview.exe` 是原生界面）。

## 6.5 用 Visual Studio 打开仓库时，CMake 提示要不要启用

用 VS 的「打开文件夹」选中 `LanPlayer` 根目录，会弹出：

> 在打开的工作区的一个或多个子目录中检测到 CMakeLists.txt 文件。是否要对此工作区启用 Visual Studio 的 CMake 支持？

**选「不启用」（点取消/关闭）。** 启用后要从头配一遍，而这里没有一个 CMake 工程是给 VS 单独用的。

### 六个 CMakeLists.txt 各自的真正主人

| 文件 | 谁驱动它 | 能不能在 VS 里单独配 |
|-|-|-|
| `native/CMakeLists.txt` | 手工 CMake；CI 的 Android/Apple 构建 | 能配，但产出没用（见下） |
| `app/windows/CMakeLists.txt` | `flutter build windows`（flutter_tools 传 `-DFLUTTER_ROOT=…` 等） | 不能，缺 `generated_config.cmake` |
| `app/windows/flutter/CMakeLists.txt` | 同上，`include` 了 `ephemeral/generated_config.cmake` | 不能，同上 |
| `app/windows/runner/CMakeLists.txt` | 同上 | 不能，同上 |
| `packages/lanplayer_video/windows/CMakeLists.txt` | 由 `app/windows/flutter/generated_plugins.cmake` include | 不能，它是插件的子目录 |
| `app/android/app/src/main/cpp/CMakeLists.txt` | Gradle 的 `externalNativeBuild` | 不适用（Windows 上没有 NDK） |

**Windows 上真正的内核构建是 `scripts/build_windows.ps1`（Zig，不走 CMake、不走 MSVC）**，
它才有自己的 libsmb2 shim 与 win32 平台适配。也就是说：**没有任何一个 CMake 目标会产出
`build/win-x64/lanplayer.dll`**，那是 Zig 那条链路独有的产物。

### 启用之后具体会坏在哪

1. **`app/windows` 配不出来。** 它 `include(flutter/generated_config.cmake)`，而那文件长这样：

   ```cmake
   # Generated code do not commit.
   file(TO_CMAKE_PATH "D:\\repo\\LanPlayer\\.tools\\flutter-sdk" FLUTTER_ROOT)
   ```

   里面是本机绝对路径，`.gitignore:20` 已把它排除（`app/windows/flutter/ephemeral/`）。
   VS 独立配置时找不到 `FLUTTER_ROOT`、`generated_plugins.cmake`，直接失败。

2. **`native/` 配得动，但配出来的是错的。** `native/CMakeLists.txt:61-65` 的平台分支是
   `if(ANDROID) … elseif(APPLE) … else()`，Windows 落进 `else()`，也就是
   **`src/platform/stub/stub_platform.c`**——没有渲染器、没有音频输出、没有 D3D11VA。
   你会以为在编内核，实际编出一个没有任何输出能力的库。

3. **多出第二个构建树。** VS 把产物放在 `out/build/<preset>` 或仓库根的 `out`，与
   `app\build\windows`、`build\win-x64` 都不重叠。FFmpeg 的 `avcodec-63.dll` 单个就 114 MB，
   多一份就是几百 MB，而且 `out/` 不在 `.gitignore` 里（`app/windows/out/` 才在，第 19 行），
   有误提交风险。第一次启用还会生成 `.vs/`（本机现在 9.4 MB，已被 `.gitignore:39` 排除）。

### 推荐的两种打开方式

**A. 只当编辑器（最省事）**

菜单「文件 → 打开 → 文件夹」选仓库根目录 → 提示里选**不启用**。浏览、搜索、改代码、
看 Git 差异都正常，构建走命令行（VS 里 `Ctrl+`` 开终端）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.ps1 -Config Release -Core -Run
```

**B. 想用 VS 的 C++ 断点/内存窗口**

只在调试 Flutter runner 与插件桥时才值得。顺序不能反：

```powershell
cd app
flutter build windows --release      # 先生成 ephemeral/generated_config.cmake
```

然后用「打开文件夹」指向 **`app\windows`**（不是仓库根目录），此时配置能成功。
但这条路径**只用于调试 UI 与插件桥**，内核仍然是 `scripts/build_windows.ps1` 出的
`lanplayer.dll`（用 `-DeployTo` 拷到 exe 旁边）。

### 顺带：VS 的 CMake 版本

VS 自带 `C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`
（本机 **4.3.1-msvc1**），`scripts/build_windows_desktop.ps1` 用的就是它，所以走 A/B 哪种都不缺 CMake。

## 6.6 GitHub Actions 的额度：为什么 job 会「3 秒失败、日志 404」

私有仓库的 Actions 有免费额度（Free 计划 **2000 分钟/月**），并且**按平台乘系数扣**：
Linux ×1、Windows ×2、macOS ×10。本仓库一次全量 CI 的实测账：

| job | 平台 | 实测原始分钟 | 系数 | 计费分钟 |
|-|-|-|-|-|
| apple (iOS build only) | macOS | 79.5 | ×10 | **794.7** |
| windows desktop app | Windows | 198.6 | ×2 | **397.1** |
| native core (Linux) | Linux | 242.6 | ×1 | 242.6 |
| android | Linux | 176.7 | ×1 | 176.7 |
| windows x64 native core | Windows | 67.6 | ×2 | 135.3 |
| **合计（32 次提交）** | | | | **1746.3** |

也就是说：**一次全量 CI ≈ 55 计费分钟，其中 macOS 那一个 job 就占 25 分钟**。
32 次推送就把 2000 分钟烧光了。额度用尽后的表现很有欺骗性：

- 每个 job 的 `steps` 是**空数组**、`runner_name` 为空、`started_at` 与 `completed_at` 只差 3 秒；
- `ci_log.py` 拉日志报 `HTTP Error 404: The specified blob does not exist`（根本没有日志）；
- 网页上只显示一排红叉，看不出原因。

真正的错误信息藏在 **check-run 的 annotations** 里（`gh api` 或 REST）：

```
The job was not started because recent account payments have failed
or your spending limit needs to be increased.
Please check the 'Billing & plans' section in your settings
```

排查命令（本仓库的辅助脚本，读 Windows 凭据管理器里的 token）：

```powershell
.tools\python\python.exe .tools\ci_probe.py            # 列最近 run 与失败 step
.tools\python\python.exe .tools\ci_cost.py             # 按计费分钟统计各 job
.tools\python\python.exe .tools\ci_usage.py            # 当月 usage（官方 billing/usage）
.tools\python\python.exe .tools\ci_annot.py <run_id>   # 打印 check-run annotations
```

修复方向有三条，本仓库已做了前两条：

1. **文档改动不再触发整套构建**（`.github/workflows/build.yml` 的 `paths-ignore`：
   `**.md`、`docs/**`、`LICENSE`、`.gitignore`、`.gitattributes`）。改一行 README
   本来就要烧 55 分钟额度，很不划算。
2. **同一分支的新推送取消旧跑批**（`concurrency: build-${{ github.ref }}` +
   `cancel-in-progress: true`），连续推几次只留最后一次。
3. **把仓库改成 public**：公共仓库的 Actions 完全免费、不扣额度。
   私有仓库也可以去 *Settings → Billing* 提高 spending limit（需要绑卡）。

> 额度用尽**不影响本地构建**：`scripts/build_windows.ps1`、`build_windows_desktop.ps1`、
> Mac 上的 `build_apple_deps.sh` + `flutter build macos` 全部照常，`tool/check_all.py` 也不依赖 CI。

## 7\. 打安装包

两个平台各一条命令，产物落在 `dist/`（已在 `.gitignore` 里，因为体积属于发布资产而非源码）。

### 7.1 Windows（NSIS）

```powershell
python tool\fetch_deps.py nsis        # 只装 NSIS 3.10 到 .tools\nsis（约 2.2 MB）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -Version 0.1.0
# -> dist\LanPlayer-0.1.0-windows-x64-setup.exe
```

脚本做四件事，任何一步失败都直接 `exit 1` 而不是留下半个包：

1. 校验 `app\build\windows\x64\runner\Release` 里的 `lanplayer.exe`、`lanplayer.dll`、
   `avcodec-63.dll`、`avformat-63.dll` 都在（缺就提示先跑 `flutter build windows --release`
   和 `scripts\build_windows.ps1 -DeployTo …`）。
2. 暂存到 `dist\stage\windows`：10 个 exe/dll（逐个列名，与 `.nsi` 里的 `File` 一一对应）
   + `data\`（`app.so`、`icudtl.dat`、`flutter_assets`）+ 6 个
   `Microsoft.VC145.CRT` 运行库（从 vswhere 定位 VS 的 Redist 目录）。
3. `makensis /DAPP_VERSION=… /DSTAGE=… /DOUTFILE=… /DAPP_ICON=…`。
4. 打印大小与 SHA256，默认清掉暂存目录（`-KeepStage` 保留，`-Open` 打开 `dist`）。

`avdevice-63.dll`（4.9 MB）**故意不打包**：`dumpbin /DEPENDENTS` 显示没有任何模块依赖它，
核心也从不调 `avdevice_*`。

安装行为（`scripts/windows/installer.nsi`）：

| 项 | 值 |
|-|-|
| 安装位置 | `%LOCALAPPDATA%\Programs\LanPlayer` |
| 权限 | `RequestExecutionLevel user`，**不弹 UAC**，不写 `Program Files` |
| 页面 | 欢迎 → 许可（`LICENSE`）→ 组件（核心必装 / 快捷方式 / 文件关联可选）→ 目录 → 安装 → 完成 |
| 语言 | 简体中文 + English（NSIS 自带 `SimpChinese.nlf`） |
| 卸载 | 删全部文件与快捷方式、清两类注册表键；**用户数据 `%APPDATA%\lanplayer` 只弹窗询问，默认保留** |

三个必须注意的细节：

- `.nsi` 必须存成 **UTF-8 with BOM**。无 BOM 时 `makensis` 直接报
  `Bad text encoding: scripts\windows\installer.nsi:1`。
  `tool/check_all.py` 的 `check_installers()` 会检查这一点。
- `makensis` 往 `%TEMP%` 写临时文件，沙盒默认位置被拒时表现为
  `Internal compiler error #12345: error creating mmap the size of 35644314.`。
  脚本已把 `TMP`/`TEMP` 重定向到 `.tools\tmp`。
- `scripts/build_windows_installer.ps1` **必须纯 ASCII 注释**：Windows PowerShell 5.1
  会按 ANSI 读无 BOM 的 `.ps1`，中文注释会变成乱码并把后面的引号吃掉，报
  `ParserError: Unexpected token ')'`。仓库里所有 `.ps1` 都遵守这条。

静默安装/卸载（CI 或脚本里用）：

```cmd
dist\LanPlayer-0.1.0-windows-x64-setup.exe /S /D=D:\some\dir
D:\some\dir\uninstall.exe /S
```

### 7.2 macOS（dmg）

```bash
# 前置：scripts/build_apple_deps.sh 与 flutter build macos --release 都已完成
VERSION=0.1.0 ./scripts/build_macos_dmg.sh
# -> dist/LanPlayer-0.1.0-macos-arm64.dmg
```

脚本流程：检查 `.app` 存在 → `ditto` 拷到暂存目录 → `ln -s /Applications` →
`codesign --verify --deep --strict` → `hdiutil create -ov -format UDZO -imagekey zlib-level=9`
→ `hdiutil verify` → 打印 SHA256。

两个坑（都写进了脚本注释，`check_installers()` 也会盯着）：

- **必须用 `ditto` 而不是 `cp -R`**：`cp -R` 会丢掉扩展属性与代码签名，
  拷出来的 `.app` `codesign --verify` 直接失败。
- **不要在同目录建小写别名**：APFS 默认大小写不敏感，`LanPlayer.app` 与
  `lanplayer.app` 是同一个目录，随后的清理会把刚拷好的 app 删掉（第一次 dmg 只有 11 KB
  且里面是空的，就是这个原因）。

签名：`flutter build macos` 默认 ad-hoc 签名（`codesign -dv` 显示 `Signature=adhoc`），
本机自用足够；**分发给别人需要 Developer ID 证书 + 公证**，否则对方打开时
Gatekeeper 会拦（`已损坏，无法打开` / `无法验证开发者`）。

### 7.3 发布到 GitHub Release

两个包打出来后直接传到 GitHub 的 Release 里，不需要 `gh` CLI（本机没装），
用 REST API 两步：先建 release（顺带建 tag），再逐个上传 asset。

```bash
# 1. 建 release + tag（tag 指向 main 当前 HEAD）
curl -sS -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  https://api.github.com/repos/LXinH3RT/LanPlayer/releases \
  -d '{"tag_name":"v0.1.0","target_commitish":"main","name":"LanPlayer 0.1.0","body":"...","draft":false,"prerelease":false}'

# 2. 传 asset（注意是 uploads.github.com，不是 api.github.com）
curl -sS -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @dist/LanPlayer-0.1.0-windows-x64-setup.exe \
  "https://uploads.github.com/repos/LXinH3RT/LanPlayer/releases/<release_id>/assets?name=LanPlayer-0.1.0-windows-x64-setup.exe"
```

两个踩过的坑：

- **必须加 `--ssl-no-revoke`**：Windows 自带 curl 走 schannel，检查吊销列表时
  报 `CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`，加这个开关即可。
- **上传目标主机是 `uploads.github.com`**：用 `api.github.com` 传会 404。

验证方式：用 `Accept: application/octet-stream` 下载
`https://api.github.com/repos/.../releases/assets/<asset_id>`，与本机文件比 SHA256
（本次两个包的哈希完全一致）。

> 仓库目前是 **private**，所以 `https://github.com/.../releases/download/v0.1.0/...`
> 这类公开直链对未登录访问者返回 404 —— 这是私有库的正常行为，不是上传失败。
> 要么让获邀协作者登录后从 Release 页面下载，要么把仓库改成 public。
> 把仓库改 public 还会顺带解决 GitHub Actions 免费额度用完的问题（见 6.6）。

#### 7.3.1 v0.1.1 的发布记录

0.1.1 是修「打开含视频的文件夹卡死」的版本（缺陷细节见 `verification.md` 3.28），
两个平台都重新出了包：

| 平台 | 文件 | 大小 | SHA256 |
|-|-|-:|-|
| Windows 10/11 x64 | `LanPlayer-0.1.1-windows-x64-setup.exe` | 55.4 MB | `8f2ff76c…d95c64` |
| macOS 12+ (Apple Silicon) | `LanPlayer-0.1.1-macos-arm64.dmg` | 25.7 MB | `602243cf…365c1d0f` |

- Release id `420674952`，tag `v0.1.1` 指向 `f578a44`（含全部修复）。
- asset id：Windows `665760452`、macOS `665761260`。
- 两个包都下载回来重算 SHA256，与本地完全一致。

Windows 包要先用 `flutter build windows --release` 把产物放到
`app/build/windows/x64/runner/Release/`（安装脚本只认这个路径），再
`build_windows.ps1 -DeployTo` 把新内核 DLL 覆盖进去——**这一步不能漏**，
否则打出来的还是旧 DLL。macOS 侧先 `flutter build macos --release`
（要在这台 Mac 上跑，静态库得是重编过的那份），再 `VERSION=0.1.1 ./scripts/build_macos_dmg.sh`。

> 静默安装到自定义目录时 `/D=` 必须是**最后一个参数**且不能带引号；
> PowerShell 里更稳的写法是
> `Start-Process -ArgumentList '/S','/D=D:\path' -Wait`。
> 若上一个安装器还停在模态框上，新的一次会卡在同一个弹窗，先 `taskkill` 掉。

## 7.4 构建后自检

```bash
python tool/check_all.py            # 一把梭：C 语法/符号、Dart 解析、原生冒烟、Dart 测试
cd app && flutter analyze && flutter test # 有 Flutter SDK 时的完整检查
```

`tool/check_all.py` 会自动跳过缺失的工具链（没有 Flutter 就不做 UI 检查），
并顺带跑一遍 Windows 上已编译的 `build\win-x64\lp_smoke_test.exe`。
实测输出记录在 [verification.md](verification.md)。

### 哪些中间产物可以安全删除

下面这些都不在 git 里，删了不影响源码，需要时按最后一列重建：

| 路径 | 删掉的代价 | 怎么重建 |
|-|-|-|
| `build\media\` | 测试素材没了；`check_all.py` 的硬解一项会自动跳过 | `powershell -File scripts\make_test_media.ps1` |
| `build\win-x64\` | 内核 DLL 与 4 个测试 exe 没了；`check_all.py` 的原生冒烟/硬解两项自动跳过 | `powershell -File scripts\build_windows.ps1` |
| `build\dart-check\` | 无所谓，每次自检都会重编 kernel | `python tool\check_all.py` |
| `build\remote\` | Mac 远程调试用的历史脚本（137 个 `.sh`），0.1 MB，留着当参考 | 无需重建 |
| `native\third_party\` | 静态库/动态库全没了，任何平台都编不动 | `scripts\build_windows.ps1` 或 `SLICES=<family> ./scripts/build_apple_deps.sh` |
| `app\build\`、`app\windows\out\`、`app\windows\flutter\ephemeral\` | Flutter 构建缓存与 CMake 中间件 | 重跑 `flutter build windows`（CMake 会重新生成 `ephemeral`） |
| `app\.dart_tool\flutter_build\` | 编译缓存；`package_config.json` 会留着，`flutter` 命令仍可用 | 重跑一次 `flutter build` |
| `dist\` | 两个安装包 | `scripts\build_windows_installer.ps1` / `scripts\build_macos_dmg.sh` |
| `.vs\` | Visual Studio 打开仓库时生成的缓存 | VS 自己会重建 |

**不能删**：`.tools\`（工具链本体，2.7 GB，只能重新 `fetch_deps.py` 下载）、
`.tools\flutter-sdk\.git`（Flutter 工具会校验它，删了直接报“不是 GitHub 仓库的克隆”）、
`.tools\flutter-sdk\bin\mingit`（这台机器上唯一可用的 git）。

## 8\. 常见问题

|现象|原因|
|-|-|
|`libavformat.so not found`|只打了 `liblanplayer.so`，FFmpeg `.so` 没随 APK 打包（检查 `abiFilters` 与 `jniLibs`）|
|硬解直接回退软解|`lp_player_set_surface` 在 `open` 之后才调用；先创建纹理再 open（UI 已是这个顺序）|
|4K 卡顿|APK 没开 `largeHeap`，或 SMB 读太慢：调大 `readahead_kb` 与 `timeout_ms`|
|iOS 链接不到 `lp_*`|漏了 Bridging Header 或静态库没加到 Link Binary With Libraries|
|字幕乱码|文件不是 UTF-8/UTF-16。Windows 上内核会用 `MultiByteToWideChar` 依次试 GB18030/GBK/Big5/Shift-JIS/CP949；Android 需要 iconv 或先转成 UTF-8|
|`Building with plugins requires symlink support`|Windows 未开启「开发者模式」或令牌无 `SeCreateSymbolicLink`：用 `scripts\fix_plugin_links.ps1` 建 junction，或直接 `scripts\build_windows_desktop.ps1`|
|`Generator Visual Studio 16 2019 could not find any instance`|装的是 VS 2026 而 flutter_tools 硬编码只认 2019/2022：先跑 `scripts\patch_flutter_tools.ps1` 注入正确 generator，或用 `scripts\build_windows_desktop.ps1`（它直接用 VS 自带的 cmake）|
|`flutter build windows` 找不到 Visual Studio|Flutter 桌面只认 MSVC，需要「使用 C++ 的桌面开发」工作负载|
|VS 提示「是否启用 CMake 支持」|选**不启用**：六个 `CMakeLists.txt` 分别归 flutter_tools / Gradle / 插件子目录，Windows 内核根本不走 CMake。详见 6.5|
|VS 里配 `app/windows` 报找不到 `FLUTTER_ROOT`|`ephemeral/generated_config.cmake` 还没生成（它是 `flutter build windows` 的产物、且不入库）：先跑一次 `flutter build windows`，再在 VS 里打开 `app\windows`|
|exe 启动即退出、无窗口|只编了 `lanplayer` 目标没跑 `INSTALL`：`data/flutter_assets`、`icudtl.dat` 不在 exe 旁。重跑 `build_windows_desktop.ps1`|
|运行时报 `lanplayer.dll not found`|DLL 不在 exe 旁边：用 `-DeployTo <输出目录>`，或设 `LANPLAYER_CORE=<DLL 所在目录>`|
|画面偏蓝（红变蓝、蓝变红）|纹理的通道顺序：内核出 **BGRA**（GDI 要的顺序），Flutter 的 `FlutterDesktopPixelBuffer` 没有格式字段、引擎一律按 **RGBA8888** 读。插件 `VideoTexture::Copy()` 必须调 `lp_bgra_to_rgba()`（`packages/lanplayer_video/windows/include/lanplayer_video/pixel_swizzle.h`）。`lp_win32_texture_test.exe ... --expect-red` 会在纯红素材上断言这件事|
|服务器列表重启后消失|状态目录不可写：设 `LANPLAYER_STATE_DIR=<可写目录>`；正常应落在 `%APPDATA%\<Company>\<Product>\lanplayer`|
|有声音但画面黑|`attachPlayer` 在 `open` 之后才调用；插件必须先拿到 player 指针（当前 UI 顺序正确）|
|硬解没生效（一直显示 `hw=software`）|`lp_hw_decoder_available()` 会缓存首次探测结果：显卡驱动不支持 D3D11VA 时永久回退软件解码，只留一条 `fallback_from` 事件。用 `lp_hw_decode_test.exe <视频>` 看真实解码器名；`--selftest` 默认钉住 `sw`，要看硬解得显式 `--hw auto`|
|老显卡 / 虚拟机里 D3D11 设备建不出来|`av_hwdevice_ctx_create(AV_HWDEVICE_TYPE_D3D11VA)` 失败即走软件路径，不影响播放；WARP 软件 D3D 设备也能吃 D3D11VA，只是没有解码加速|



