# 构建指南

本仓库只包含源码：FFmpeg 与 libsmb2 需要按下面的步骤自己编译，产物放进
`native/third_party/`（已被 `.gitignore` 忽略）。

## 0\. 目录约定

```
native/third_party/
├─ ffmpeg/
│  ├─ android/arm64-v8a/{include,lib/arm64-v8a/*.so}
│  ├─ android/armeabi-v7a/{include,lib/armeabi-v7a/*.so}
│  ├─ apple/{include,lib/*.a}          # iOS device + simulator + macOS
│  └─ desktop/{include,lib/*.a}        # 可选：Windows/Linux 本地调试
└─ libsmb2/
   ├─ android/{include,lib/<abi>/libsmb2.so}
   └─ apple/{include,lib/libsmb2.a}
```

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
./scripts/build_apple_deps.sh
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
  --cc="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0" \
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
brew install --cask flutter      # Homebrew 装的是 stable，含 Dart SDK
#    或者手动下载（想锁版本时用这个）：
#    https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_3.27.4-stable.zip
#    unzip 到 ~/development 后把 bin 加进 PATH：
#    echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc

flutter --version                # 必须能在任意目录打印版本，再去 app/ 里构建

# 6) 用 flutter doctor 一次性确认 Xcode / CocoaPods / Flutter 三者都认到了
flutter doctor -v
#    要看到 [✓] Flutter、[✓] Xcode (含 CocoaPods installed)、[✓] Connected device
#    出现 [!] Xcode ... CocoaPods not installed 就是第 3 步没生效；
#    出现 [!] Xcode ... requires Xcode 就是还停在 Command Line Tools。
```

> Homebrew 的 `flutter` cask 会自动装好 Dart SDK，但**不会**帮你跑 `flutter doctor --android-licenses`
> 之类的东西；Apple 侧用不到 Android 那部分，忽略 doctor 里的 Android 那一行即可。

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
./scripts/build_apple_deps.sh                 # 三切片：iphoneos / iphonesimulator / macosx
SLICES=macosx ./scripts/build_apple_deps.sh   # 只做 macOS，快很多
ARCHS="arm64 x86_64" ./scripts/build_apple_deps.sh   # Intel Mac 再加 x86_64
```

产出（全部是 universal 静态库，已按切片 `lipo` 合并）：

| 路径 | 内容 |
| --- | --- |
| `native/third_party/ffmpeg/apple/lib` | `libavformat.a` `libavcodec.a` `libavutil.a` `libswresample.a` `libswscale.a` `libavfilter.a` |
| `native/third_party/libsmb2/apple/lib` | `libsmb2.a` |
| `native/third_party/lanplayer/apple/lib` | `liblanplayer.a` ← **C 内核自己**（16 个 .c：核心 13 个 + `platform/apple` 3 个） |

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
- `app/ios/Podfile` 与 `app/macos/Podfile` 已存在（`platform :ios, '13.0'` / `platform :osx, '11.0'`，
  与 `build_apple_deps.sh` 的 `MIN_IOS`/`MIN_MACOS` 对齐），里面没有手写 `pod` 行——
  Flutter 会读 `.flutter-plugins-dependencies`，自动把 `lanplayer_core` 装上。
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
`building for iOS 13.0, but linking in object file built for iOS 14.0`，说明
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

### 4.7 macOS 上首次构建会遇到的错误（按出现顺序）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `zsh: permission denied: ./scripts/build_apple_deps.sh` | 仓库里的 `.sh` 是 `100644` | `chmod +x scripts/*.sh`（每次新克隆一次） |
| `zsh: command not found: flutter` | 装 Xcode / Homebrew / CocoaPods 都不会顺手装 Flutter | `brew install --cask flutter`，再确认新终端里 `flutter --version` 可用（见 4.1 第 5 步） |
| `cmake: command not found` | macOS 不带 cmake | `brew install cmake` |
| `Compatibility with CMake < 3.5 has been removed` | libsmb2 要求 3.2，CMake 4.x 不支持 | 脚本已传 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`，更新仓库即可 |
| `krb5-wrapper.c: unknown type name 'gss_const_OID'` 等 18 个 error | macOS 有 GSSAPI 头但缺 MIT/Heimdal 扩展 | 脚本已传 `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE`，更新仓库即可 |
| `You don't have write permissions for /Library/Ruby/Gems/2.6.0` | 系统 ruby 的 gem 目录只读 | 不要 `sudo gem install`，用 `brew install cocoapods` |
| `xcodebuild: error: ... requires Xcode, but active developer directory ... is a command line tools instance` | 只装了 Command Line Tools | 装完整 Xcode 后 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `library not found for -llanplayer` | 4.2 没成功（`native/third_party/lanplayer/apple/lib` 不存在） | 重跑 `SLICES=macosx ./scripts/build_apple_deps.sh` |
| `building for macOS 11.0, but linking in object file built for macOS 14.0` | 依赖用了更高的部署目标 | `MIN_MACOS=11.0` 重编，或把 `app/macos/Podfile` 与工程目标一起调高 |
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

## 7\. 构建后自检

```bash
python tool/check_all.py            # 一把梭：C 语法/符号、Dart 解析、原生冒烟、Dart 测试
cd app && flutter analyze && flutter test # 有 Flutter SDK 时的完整检查
```

`tool/check_all.py` 会自动跳过缺失的工具链（没有 Flutter 就不做 UI 检查），
并顺带跑一遍 Windows 上已编译的 `build\win-x64\lp_smoke_test.exe`。
实测输出记录在 [verification.md](verification.md)。

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



