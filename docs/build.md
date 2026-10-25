# 构建指南
本仓库只含源码：FFmpeg 与 libsmb2 要自己编译，产物放进 `native/third_party/`（已被 `.gitignore` 忽略）。顺序：装工具链（0.5 Windows / 4.1 Apple）→ 编依赖与内核（1、2 节，或用 `scripts/` 一键脚本）→ 编 app 与安装包（3、4、5、7 节）。报错先查 4.7 / 4.8 / 第 8 节。

## 0. 目录约定
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

`<family>` = `macosx` / `iphoneos` / `iphonesimulator`。每个平台族写自己的目录，podspec 用 `$(PLATFORM_NAME)` 选目录，所以 macOS 与 iOS 的库能共存、交错构建不互相覆盖（`apple/lib` 只是给老路径兜底的扁平副本）。整个 `native/third_party/` 是生成物（几百 MB），不进 git，删了重跑 `scripts\build_windows.py` 或 `SLICES=macosx python3 scripts/build_apple_deps.py`；`native/CMakeLists.txt` 用 `LP_FFMPEG_ROOT` / `LP_SMB2_ROOT` 找它们（Android 由 Gradle 传参、Apple 由 Xcode 传参）。

## 0.5 Windows（Zig，一条命令）
不需要 Visual Studio 或 MSYS2：`tool/fetch_deps.py` 把固定版本的工具与依赖下到 `.tools/`，`scripts/build_windows.py` 负责编译、链接并复制运行时 DLL。

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.py -Clean -RunSmoke
```

|组件|版本 / 说明|
|-|-|
|Zig|0.13.0（clang 18 + mingw-w64 libc + lld）|
|FFmpeg|官方 Windows 共享构建 `N-127650`（libavutil 61，mingw 版，带 `lib*.dll.a`）|
|libsmb2|v4.0.0 源码，48 个文件全部编过并归档为 `libsmb2.a`|
|产物|`build/win-x64/{lanplayer.dll, lp_smoke_test.exe}` + FFmpeg DLL|

平台适配都在仓库里，不用改上游：`native/src/platform/desktop/win32_pthread.h` 用 SRWLOCK / CONDITION_VARIABLE / CreateThread 补 mingw 缺的 pthread；`native/platform/win32/smb2/` 补齐 `sys/socket.h`、`poll.h`、`arpa/inet.h`、`netinet/in.h`、`netdb.h`、`asprintf.h`、`win32_compat.h`（上游 `include/msvc/sys/socket.h` 用裸 `inline` 定义 `close/readv/writev`，GCC/Clang 下会重复定义，这里换成 `lp_win_*` + 宏）；`LP_HAVE_SMB2` 关掉时 `smb.c` 编成空翻译单元，运行时把 `smb` 报为不支持的协议（CI 的 Linux job 就这样跑）。`-RunSmoke` 的自检输出应为：

```
abi=1
schemes=\["smb","file","http","https"]
no media given: library smoke test passed
```

## 1. FFmpeg
脚本已自动化，推荐直接用（产物落在 `native/third_party/`，布局见第 0 节）：

```bash
ANDROID_NDK_HOME=~/android-ndk-r26 ./scripts/build_android_deps.py
python3 scripts/build_apple_deps.py                 # 默认只做 macosx 切片
SLICES=iphoneos python3 scripts/build_apple_deps.py # 要编 iOS App 时再跑一次
```

需要 `avformat avcodec avutil swresample swscale avfilter`，**不要** `--disable-everything` 那种极限裁剪，至少保留：

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

`--enable-mediacodec` 只影响 FFmpeg 自带的 hwaccel；本项目的 MediaCodec 零拷贝路径是自己实现的，这个开关属「备用」，开着无害。

### iOS / macOS
```bash
./configure --prefix=/tmp/ff/apple --enable-cross-compile \
  --target-os=darwin --arch=arm64 \
  --cc="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0" \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-static --disable-shared --disable-programs --disable-doc
```

要为 `iphoneos`（arm64）、`iphonesimulator`（arm64/x86_64）、`macosx` 各编一份，再用 `lipo` 合并模拟器的两个架构。注意本项目**直接调用 VTDecompressionSession**（`platform/apple/videotoolbox_decoder.c`），FFmpeg 只负责解封装与音频。

## 2. libsmb2
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

要求 libsmb2 **≥ 4.0**（用到 `smb2_stat_64`、`smb2_lseek`、目录接口）。要在 SMB 层做断线重连，可在 `smb.c` 里调 `smb2_set_autoreconnect(ctx, 1)`（4.1+）。

## 3. Android
```bash
cd app
flutter create --platforms=android,ios,macos .   # 只生成脚手架，不覆盖已有文件
flutter pub get
flutter build apk --release --target-platform android-arm64
```

配置已就位：`android/app/build.gradle.kts` 的 `minSdk 26`（AAudio）、`abiFilters arm64-v8a`（只出这一种 ABI）、`externalNativeBuild` 指向 `src/main/cpp/CMakeLists.txt` 并传 `LP_FFMPEG_ROOT` / `LP_SMB2_ROOT`；`src/main/cpp/CMakeLists.txt` 做 `add_subdirectory(native)`；`AndroidManifest.xml` 有网络/媒体读权限与 `usesCleartextTraffic`。产物：`liblanplayer.so`（含 JNI 符号）+ 随包打入的 FFmpeg `.so`。

`ndkVersion` 是 `System.getenv("LP_ANDROID_NDK") ?: "26.1.10909125"`，可用环境变量覆盖。要先有 NDK 和交叉编译出来的依赖：

```bash
# NDK r26b 正是 26.1.10909125
curl -fL -o ndk.zip https://dl.google.com/android/repository/android-ndk-r26b-darwin.zip
unzip -q ndk.zip -d ~ && export ANDROID_NDK_HOME=~/android-ndk-r26b
./scripts/build_android_deps.py arm64-v8a      # FFmpeg 6.1.1 + libsmb2 + 内核
```

真机上跑过一次，过程中会撞到三件事：

1. **`make` 必须有。** `scripts/build_android_deps.py` 是 bash 脚本，交叉编译 FFmpeg 依赖 `make`；Git Bash 里没有 `make`，所以 Windows 不是合适的构建机。Mac 上有。
2. **Gradle Wrapper 下载证书报 `PKIX path building failed`。** 装了会做 MITM 的代理（比如 SteamTools）时，JVM 不认它的根证书。把该根证书导入 `$JAVA_HOME/lib/security/cacerts`。
3. **JDK 太新会让 Gradle 8.3 直接拒绝。** 构建脚本里显式 `export JAVA_HOME="$(/usr/libexec/java_home -v 17)"`；之后增量构建只要 1.5–1.8 s。

装机：`adb install -r app/build/app/outputs/flutter-apk/app-release.apk`。MIUI 上第一次会报 `INSTALL_FAILED_USER_RESTRICTED`，是开发者选项里的「USB 安装」没开，不是包的问题。

`/storage/emulated/0` 的媒体读权限由 app 自己申请：manifest 只声明 `READ_MEDIA_VIDEO`（不声明 audio，否则一次弹两个框），`MainActivity.kt` 的 `lanplayer/permissions` 通道负责 `requestPermissions`，`app/lib/ui/media_permission.dart` 在 `_openLocal()` 进目录前调用，返回值带 `partial` 以覆盖 Android 14 的「选择部分」。

看内核日志：`adb logcat -s LanPlayer`（`native/src/util/lp_log.c` 把模块名放进正文，tag 固定是 `LanPlayer`）。

## 4. iOS / iPadOS / macOS
Apple 侧没有 CMake 也不用 MSBuild：**先在 Mac 上把 FFmpeg / libsmb2 / C 内核编成静态库，再由 CocoaPods 链进 Runner。**

### 4.1 准备（只需一次）
```bash
xcode-select --install          # 先装命令行工具
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cocoapods
pod --version                   # 1.17.x
brew install cmake
cmake --version                 # 4.x，脚本已用 CMAKE_POLICY_VERSION_MINIMUM 兼容
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
mkdir -p ~/development && cd ~/development
#    Apple Silicon 用 arm64 包（1.49 GB），Intel 用不带 arm64 的那个：
curl -L -o flutter.zip \
  https://storage.flutter-io.cn/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.27.4-stable.zip
unzip -q flutter.zip && rm flutter.zip
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.zshrc
echo 'export PUB_HOSTED_URL=https://pub.flutter-io.cn' >> ~/.zshrc
echo 'export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn' >> ~/.zshrc
source ~/.zshrc
flutter --version --no-version-check
flutter precache --macos         # 从镜像拉 macOS 引擎产物（含 Dart SDK，约 450 MB）
flutter doctor -v
#    xattr -dr com.apple.quarantine ~/development/flutter   # 仅在真弹 "flutter 已损坏" 时
```

| 步骤 | 为什么 / 注意 |
|-|-|
| `xcode-select -s` | `flutter build macos` 要完整 Xcode，只有 Command Line Tools 时在构建早期报 `xcodebuild: error: ... requires Xcode` |
| `brew install cocoapods` | 系统 Ruby 的 gem 目录 `/Library/Ruby/Gems/2.6.0` 只读，`sudo gem install` 必报 `You don't have write permissions` |
| Flutter 下载 | 装 Xcode / Homebrew / CocoaPods 都不会顺带装 Flutter；`brew install --cask flutter` 直连 `storage.googleapis.com` 拉 1.3 GB，实测常只有几十 KB/s，所以用 CFUG 镜像下同一个包 |
| `flutter doctor -v` | 要看到 `[✓] Flutter`、`[✓] Xcode`（含 CocoaPods installed）、`[✓] Connected device`。`CocoaPods not installed` = 第 3 步没生效；`requires Xcode` = 还停在 Command Line Tools |

镜像变慢时换上海交大 `PUB_HOSTED_URL=https://mirror.sjtu.edu.cn/dart-pub` + `FLUTTER_STORAGE_BASE_URL=https://mirror.sjtu.edu.cn`，或清华 TUNA `PUB_HOSTED_URL=https://mirrors.tuna.tsinghua.edu.cn/dart-pub` + `FLUTTER_STORAGE_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/flutter`。装完卡住时先确认镜像变量与 SDK 缓存（`flutter` 会按 `bin/cache/flutter_tools.snapshot` 与 SDK 版本是否匹配决定要不要重编 flutter tool，停在 `Building flutter tool...` 且无进度输出很像卡死，冷启动其实约 3 分钟）：

```bash
ps aux | grep -E 'dart|gen_snapshot' | grep -v grep   # 有 -> 正在编，等到出号
echo $PUB_HOSTED_URL                                  # https://pub.flutter-io.cn
echo $FLUTTER_STORAGE_BASE_URL                        # https://storage.flutter-io.cn
curl -sI https://storage.flutter-io.cn/flutter_infra_release/releases/releases_macos.json | head -1
flutter --version --no-version-check
flutter precache --macos
```

脚本都是 Python，不需要执行位：一律用 `python3 scripts/xxx.py` 调用。

首次 `pod install` 要拉 Specs 仓库（约 250 MB 到 `~/.cocoapods/repos/master`），慢的话先 `git clone --depth 1 https://github.com/CocoaPods/Specs.git ~/.cocoapods/repos/master`。

### 4.2 编静态库
```bash
cd /path/to/LanPlayer
python3 scripts/build_apple_deps.py                 # 默认只做 macosx（桌面构建用这个）
SLICES=iphoneos python3 scripts/build_apple_deps.py # 做 iOS 真机切片
SLICES=iphonesimulator python3 scripts/build_apple_deps.py  # 做 iOS 模拟器切片
ARCHS="arm64 x86_64" python3 scripts/build_apple_deps.py   # Intel Mac 再加 x86_64
```

**一次只能做一个平台族，三个族可以共存**：Apple silicon 上三个族都是 arm64，`lipo` 不允许两个同架构切片进同一个 fat 归档（`have the same architectures (arm64) and can't be in the same fat output file`），所以脚本开头检查 `SLICES` 就直接退出，不会白编二十分钟。

| 路径 | 内容 |
| --- | --- |
| `native/third_party/ffmpeg/apple/<family>/lib` | `libavformat.a` `libavcodec.a` `libavutil.a` `libswresample.a` `libswscale.a` `libavfilter.a` |
| `native/third_party/libsmb2/apple/<family>/lib` | `libsmb2.a` |
| `native/third_party/lanplayer/apple/<family>/lib` | `liblanplayer.a` ← **C 内核自己**（16 个 .c：核心 13 + `platform/apple` 3） |
| `native/third_party/*/apple/lib` | 最近一次构建那一族的副本（兜底，带 `.family` 标记） |

这一步会下载 FFmpeg 6.1.1 与 libsmb2 v4.0.0 到 `build/deps/` 并编译十几分钟；FFmpeg 编完会缓存（`build/deps/ff-<slice>/lib/libavcodec.a` 存在就跳过），强编用 `FORCE=1 python3 scripts/build_apple_deps.py`。脚本里两处针对 macOS 的必需开关：

- `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE` / `..._OpenSSL=TRUE`：libsmb2 无条件 `find_package(GSSAPI)`，macOS 自带 `libgssapi_krb5.tbd` 与 `gssapi/gssapi.h`，于是 `HAVE_LIBKRB5` 被定义并去编 `lib/krb5-wrapper.c`——它用的 `gss_const_OID`、`gss_acquire_cred_with_password`、`gss_buffer_set_t`、`gss_set_neg_mechs`、`gss_inquire_sec_context_by_oid` 都是 MIT/Heimdal 扩展，Apple 的 GSS.framework 没有，Xcode 15 起隐式函数声明是硬错误，于是 `17 warnings and 18 errors` 卡在 `krb5-wrapper.c.o`。本项目只用 NTLM，关掉即可。（**不要**加 `-DUSE_KRB5=OFF`：libsmb2 没这个变量，CMake 只会打一句 `Manually-specified variables were not used by the project`。）
- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`：libsmb2 v4.0.0 写的是 `cmake_minimum_required(VERSION 3.2)`，CMake 4.x 删除了 `< 3.5` 兼容性，配置阶段直接报 `Compatibility with CMake < 3.5 has been removed`。

### 4.3 接进 Flutter 工程
**不需要打开 Xcode 点任何东西**，仓库里已配好：`packages/lanplayer_core/` 是 `ffiPlugin: true` 的 Dart 空包，`ios/` 与 `macos/` 各一个 podspec（把 `native/include` 加进 `HEADER_SEARCH_PATHS`、库目录加进 `LIBRARY_SEARCH_PATHS`、`-llanplayer -lavformat -lavcodec -lswresample -lavfilter -lswscale -lavutil -lsmb2` 加进 `OTHER_LDFLAGS`，并链接 VideoToolbox CoreMedia CoreVideo AudioToolbox CoreFoundation Security 与 `z bz2 lzma iconv`）；`app/pubspec.yaml` 已声明 `lanplayer_core: {path: ../packages/lanplayer_core}`；`app/{ios,macos}/Podfile` 的 `platform` 是 15.0 / 12.0，与 `build_apple_deps.py` 的 `MIN_IOS`/`MIN_MACOS` 对齐，`post_install` 会把每个 pod 的部署目标统一抬到 15.0 / 12.0（第三方插件自带更低数字，低于 Xcode 受支持下限会报 `Target Integrity`）；四个 xcconfig 首行用 `#include?` 引入 Pods 配置，没跑过 `pod install` 也不会配置失败；`SWIFT_OBJC_BRIDGING_HEADER` 已写进两个工程，Swift 才看得到 `lp_player_*`。

```bash
cd app
flutter pub get
flutter build macos --release     # 或 flutter build ios --release --no-codesign
```

`library not found for -llanplayer` = 4.2 没跑或没成功；`building for iOS 14.0, but linking in object file built for iOS 15.0` = 依赖用了更高的 `MIN_IOS`，把工程目标同步调高或重跑 4.2。

### 4.4 桌面纹理与音频
`app/macos/Runner/MainFlutterWindow.swift` 注册 `lanplayer/video` 通道，`PlayerTexture` 从内核拉 `CVPixelBuffer` 交给引擎（BGRA，带图形字幕叠加）；iOS 侧是 `app/ios/Runner/AppDelegate.swift` 的同款实现。音频走 `native/src/platform/apple/coreaudio_sink.c`（AudioQueue，3×20 ms），视频解码走 `native/src/platform/apple/videotoolbox_decoder.c`。

### 4.5 权限
`app/ios/Runner/Info.plist` 已含 `NSLocalNetworkUsageDescription`、`NSBonjourServices`(`_smb._tcp`)、`UIBackgroundModes=audio`、`UIFileSharingEnabled`、四个方向。`app/macos/Runner/{DebugProfile,Release}.entitlements` 已含 `com.apple.security.network.client`（**没有它会拦掉 SMB 端口出站**）与 `com.apple.security.files.user-selected.read-only`。

### 4.6 真机/模拟器
```bash
flutter devices
flutter run -d <device-id>            # 调试
flutter build ipa --release           # 打包（需要签名）
```

iPad 与 iPhone 同一个包（`TARGETED_DEVICE_FAMILY = "1,2"`）。模拟器测不了 SMB 真实吞吐，但能测 UI、字幕与交互。已跑通：VideoToolbox 硬解、AudioQueue 48 kHz 立体声、外挂 SRT 字幕、纹理上屏。

#### 4.6.1 真机：Xcode 27 里找不到「Devices and Simulators」
Xcode 27 把它拆成独立 app `Device Hub`，所以 `Window` 菜单里没有这一项：

```bash
open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app
xcrun devicectl list devices                        # 看设备列表
xcrun devicectl device info details --device <UDID> # 看配对/开发者模式
```

`xcrun xcdevice list` 在 Xcode 27 上**只列模拟器**——它没坏，只是不再枚举实体设备。

#### 4.6.2 USB 插上了但设备不出现
`ioreg -p IOUSB -w0 -l` 里能看到设备（`idVendor = 1452`）而 `devicectl` 只有模拟器，几乎都是 **iPad 锁屏了**：锁屏时不启用暴露 `com.apple.mobiledevice` 的 data 配置，也弹不出「信任这台电脑吗」。解锁后立刻能列出。

```bash
$HOME/.lpvenv/bin/pymobiledevice3 usbmux list   # 空数组 [] = 没枚举到
```

#### 4.6.3 无线调试默认是关的
`flutter devices` 只看 USB 设备；无线调试打开一次后长期生效：

```bash
pymobiledevice3 lockdown wifi-connections on
pymobiledevice3 lockdown wifi-connections     # 确认 EnableWifiConnections: true
```

之后 `usbmux list` 会有两条同 UDID 记录（`Network` 与 `USB`）。`flutter devices` 末尾仍打印 `No wireless devices were found.`——它在找**只**在网络上的设备，不代表无线没通。

#### 4.6.4 真机安装：`flutter install` 在 Xcode 27 上不可用
Xcode 27 删掉了旧的 MobileDevice 栈，装真机要走 `devicectl`：

```bash
TEAM_ID=<TEAM_ID> python3 scripts/ios_device_install.py
```

脚本做四件事：把 `DEVELOPMENT_TEAM` 写进 `app/ios/Runner.xcodeproj/project.pbxproj`（每个 `PRODUCT_BUNDLE_IDENTIFIER` 的 target 都要有，否则报 `Signing for "Runner" requires a development team`）→ `flutter build ios --release` → `xcrun devicectl device install app` → `xcrun devicectl device process launch`。真机静态库要先单编一次（默认 `ARCHS=arm64`），产出在 `native/third_party/*/apple/iphoneos/lib/`，与 macOS / 模拟器两族并存（见 4.2）：

```bash
SLICES=iphoneos python3 scripts/build_apple_deps.py
```

没登录 Apple ID 的机器可以先用 `flutter build ios --release --no-codesign` 验证代码能否为 arm64 编过。三个必踩点：

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject
# subject= /UID=.../CN=Apple Development: .../OU=<TEAM_ID>/O=.../C=US
#                                               ^^ Team ID
security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db
```

| 坑 | 现象 / 机制 | 修法 |
|-|-|-|
| Team ID 不必等 Xcode 界面 | 证书 subject 里就有 | 上面 `security find-certificate ... \| openssl x509 -noout -subject` |
| SSH 非交互会话签不了名 | `codesign` 报 `Failed to codesign .../Flutter.framework/Flutter with identity ...`，根因是 `security show-keychain-info` 返回 `User interaction is not allowed.` | login keychain 无密码时先解一次锁（脚本不含这步，不宜写死空密码）：`security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db` |
| 卸载重装重置开发者信任 | profile 仍 `Valid`，启动报 `error 10002 ... its profile has not been explicitly trusted by the user` | 在 `设置 → 通用 → VPN与设备管理` 手动点一次信任，**没有命令行替代方案** |

信任恢复后 `devicectl device process launch --console` 就能直接读内核日志（内核走 `fprintf(stderr, ...)`），不需要 `flutter run`；真机截图也只能用 `devicectl`（`simctl io` 只对模拟器有效）：

```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> dev.lanplayer.lanplayer
# [LanPlayer I videotoolbox] session ready 1920x820 (h264)
# [LanPlayer I video] hardware decode videotoolbox 1920x820
# [LanPlayer I audioqueue] started 48000Hz x2
xcrun devicectl device capture screenshot --device <UDID> --destination out.png
# Dimensions: 真机分辨率
```

模拟器上的验证钩子：iOS 的 app 由 launchd 拉起，Dart 的 `Platform.environment` **永远是空表**，`SIMCTL_CHILD_LANPLAYER_OPEN=...` 进了进程环境（`ps eww -p <pid>` 能看到）但 Dart 读不到，要改用编译期注入：

```bash
cd app
flutter build ios --simulator --debug \
  --dart-define=LANPLAYER_OPEN=/Users/me/lptest/clip.mp4 \
  --dart-define=LANPLAYER_STATE_DIR=/Users/me/lptest/state
xcrun simctl install <dev> build/ios/iphonesimulator/Runner.app
xcrun simctl launch --console-pty <dev> dev.lanplayer.lanplayer   # 内核日志走这里
```

`--console-pty` 是关键：内核的 `[LanPlayer I ...]` 只出现在 app 的 stdout/stderr，`xcrun simctl spawn <dev> log show` 只能看到 `flutter:` 那些。模拟器截图可用（`xcrun simctl io <dev> screenshot --type=png out.png`），这点与 macOS 桌面端相反。

#### 4.6.5 macOS 往共享里写 `.DS_Store`：不是本 app 干的
**结论：写入者是 Finder / macOS 的 SMB 客户端，不是播放器。** 内核访问 SMB 只有 `smb2_open(..., O_RDONLY)` 与 `smb2_opendir()` 两种调用（`native/src/source/smb.c`），全仓库搜不到 `smb2_write` / `smb2_create` / `smb2_unlink` / `O_CREAT`。正解是在 Mac 上关掉这个行为（用户级，不需要 root）：

```bash
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
killall Finder          # 必须重启 Finder，否则旧的偏好还在内存里
```

**`killall Finder` 不能省**：只写 defaults 不重启 Finder，`open <挂载点>` 打开一个目录，根目录立刻又冒出 `.DS_Store`；重启后同样的动作根目录与子目录都干净。已有历史文件要单独删。验证挂载点要 URL 转义中文共享名：

```bash
mount_smbfs "//share:pass@192.168.1.10/%E5%A4%9A%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6" ~/mnt
```

开关只影响这台 Mac，别的 Mac 与 Windows 资源管理器（`Thumbs.db`/`desktop.ini`）各写各的。所以内核另做一层过滤：列表里不显示 `.DS_Store`、`._*`、`desktop.ini`、`Thumbs.db`、`.Trashes` 等元数据文件（`lp_is_os_junk_name()`，SMB 与本地路径都走）。回归测试 `native/tests/lp_junk_test.c`：负向对照去掉过滤后立刻报 `entries=6 leaked=5`。

### 4.7 iOS 上会遇到的错误
| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动即 SIGTRAP，日志里有 `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` | iOS 26/27 SDK 要求 app 采用 UIScene 生命周期 | 已修：`Info.plist` 声明 `UIApplicationSceneManifest`、去掉 `UIMainStoryboardFile`，`AppDelegate` 自持 `FlutterEngine`，由 `SceneDelegate` 建窗口 |
| 一打开视频就 SIGABRT，栈顶 `-[FlutterEngine registrarForPlugin:]` + `NSAssertionHandler` | `registrarForPlugin:` 对同名插件只能调一次 | 已修：`AppDelegate` 在 `attach()` 里取一次 `registrar` / `textures` 缓存复用 |
| `SIMCTL_CHILD_LANPLAYER_OPEN` 设了但不自动打开视频 | iOS 上 Dart 的 `Platform.environment` 是空表 | 改用 `--dart-define=LANPLAYER_OPEN=...`（见 4.6.4） |
| `Target debug_unpack_ios failed: Binary .../Flutter.framework/Flutter does not contain architectures "arm64 x86_64"` | Flutter SDK 的模拟器切片架构与工程 `ARCHS` 不匹配 | 已修：`app/ios/Flutter/*.xcconfig` 收紧到 `ARCHS = arm64` |
| `The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 13.0, but the range ... is 15.0 to ...` | Xcode 27 把 iOS 最低部署目标抬到 15.0 | 已修：`Podfile` / `project.pbxproj` / `AppFrameworkInfo.plist` / podspec 四处统一到 15.0，`post_install` 再兜一层 |
| `vf_scale_vt.c: 'VTPixelTransferSessionCreate' is only available on iOS 16.0 or newer` | `--enable-videotoolbox` 会拉进 `scale_vt` 滤镜，其 API 在 iOS 16 才有 | 已修：`build_apple_deps.py` 加 `-Wno-error=unguarded-availability-new` 并裁剪滤镜列表 |
| `sed: 1: "s\|(PRODUCT_BUNDLE_IDENT ...": unescaped newline inside substitute pattern` | BSD sed 的替换式里不能有真正的换行 | 已修：改用 `awk` 匹配 `PRODUCT_BUNDLE_IDENTIFIER` 后按原缩进追加一行 |
| `Failed to codesign .../Flutter.framework/Flutter with identity ...`（`security show-keychain-info` 报 `User interaction is not allowed.`） | SSH 非交互会话没有钥匙串访问权 | `security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db`（见 4.6.4） |
| `error 10002 ... its profile has not been explicitly trusted by the user` | 卸载重装后开发者信任被重置；profile 仍报 `Valid` | 在 `设置 → 通用 → VPN与设备管理` 点一次信任（见 4.6.4） |
| `error: Signing for "Runner" requires a development team.` | 没有 `DEVELOPMENT_TEAM`，且没登录 Apple ID（`security find-identity -v -p codesigning` 返回 0 valid identities） | 登录 Apple ID 生成 Apple Development 证书，再 `TEAM_ID=<TEAM_ID> python3 scripts/ios_device_install.py`（见 4.6.4） |

### 4.8 macOS 上首次构建会遇到的错误
| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `error: SLICES spans more than one platform family` | 一次跑了多个族，都是 arm64，`lipo` 不接受同架构切片进同一个 fat 归档 | 一次只做一个族：`SLICES=macosx`（默认）/ `iphoneos` / `iphonesimulator` |
| `zsh: command not found: flutter` | 装 Xcode / Homebrew / CocoaPods 不会顺手装 Flutter | 按 4.1 第 5 步从镜像装，再在新终端确认 `flutter --version` |
| `flutter --version` 停在 `Building flutter tool...` | 首次要编 flutter tool（`pub upgrade` + 编快照），无进度输出 | 正常，约 3 分钟；`ps aux \| grep dart` 能看到进程。要重来：Ctrl-C 后 `rm -rf ~/development/flutter/bin/cache/flutter_tools.snapshot` |
| `flutter --version` 卡 30 s 以上才回 | 默认每 3 天做一次版本检查 | `flutter --version --no-version-check`，或 `export FLUTTER_SUPPRESS_ANALYTICS=true` |
| `Can not install platforms and resources: signal timed out` | 没走镜像，直连 `storage.googleapis.com` | 先 `echo $FLUTTER_STORAGE_BASE_URL`（应为 `https://storage.flutter-io.cn`），再 `flutter precache -v --macos` 看实际 URL |
| `Downloaded executables cannot execute on host` / `Flutter requires the Rosetta translation environment on ARM Macs` | 引擎产物混进 x86_64 的 `gen_snapshot`，Apple Silicon 没装 Rosetta | `sudo softwareupdate --install-rosetta --agree-to-license`。**不做这步 `flutter build macos` 会在 AOT 那步直接死掉** |
| `[!] Xcode ... Xcode installation is incomplete; a full installation is necessary` | 只装了 Command Line Tools，或 Xcode 没跑首次启动 | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch`（还要 `-license accept`） |
| `Unable to find a device matching { platform:macOS, arch:arm64 }` | Flutter 3.27 在 macOS 26 / Xcode 26 上认不出 macOS 设备（[flutter#183353](https://github.com/flutter/flutter/issues/183353)） | 先用 `flutter run -d macos` 确认；必要时把 Flutter 升到能识别该 Xcode 的版本 |
| `cmake: command not found` | macOS 不带 cmake | `brew install cmake` |
| `Compatibility with CMake < 3.5 has been removed` | libsmb2 要求 3.2，CMake 4.x 不支持 | 脚本已传 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` |
| `krb5-wrapper.c: unknown type name 'gss_const_OID'` 等 18 个 error | macOS 有 GSSAPI 头但缺 MIT/Heimdal 扩展 | 脚本已传 `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE` |
| `You don't have write permissions for /Library/Ruby/Gems/2.6.0` | 系统 ruby 的 gem 目录只读 | 不要 `sudo gem install`，用 `brew install cocoapods` |
| `xcodebuild: error: ... requires Xcode, but active developer directory ... is a command line tools instance` | 只装了 Command Line Tools | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `Failed to load 'lanplayer_core' podspec: undefined method 'lanplayer_repo_root' for module Pod` | CocoaPods 1.16 起在 `module Pod` 作用域里 eval podspec，顶层 `def` 变成 `Pod` 的实例方法 | 已修：改成 `LP_ROOT = begin … end`，按 `native/src/core/player.c` 标记向上找仓库根 |
| `The 'lanplayer_core' pod failed to validate ... File patterns must be relative and cannot start with a slash (preserve_paths)` | `preserve_paths` 用了绝对路径，CocoaPods 校验直接判死 | 已修：删掉 `preserve_paths`，链接靠 `user_target_xcconfig` 的 `LIBRARY_SEARCH_PATHS` / `HEADER_SEARCH_PATHS` |
| `WARN \| [OSX] keys: Missing primary key for \`source\` attribute` | `s.source = { :path => '.' }` 没有主键 | 已修：改成 `{ :git => '…LanPlayer.git', :tag => s.version.to_s }` |
| `library not found for -llanplayer` | 4.2 没成功（`native/third_party/lanplayer/apple/<family>/lib` 不存在） | 重跑对应族的 `SLICES=macosx python3 scripts/build_apple_deps.py` |
| `ld: building for 'macOS', but linking in object file (…liblanplayer.a[2](lp_str.o)) built for 'iOS-simulator'` | 旧脚本把三族归档写进同一个 `apple/lib`，做 iOS 时覆盖了 macOS 那份 | 已修：按族写 `apple/<family>/lib`，podspec 用 `$(PLATFORM_NAME)` 选目录；更新后重跑一次 `SLICES=macosx python3 scripts/build_apple_deps.py` |
| `building for macOS 12.0, but linking in object file built for macOS 14.0` | 依赖用了更高的部署目标 | `MIN_MACOS=12.0` 重编，或把 `app/macos/Podfile` 与工程目标一起调高 |
| `The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to 10.14/11.0, but the range ... is 12.0 to ...` | Xcode 26 把最低部署目标抬到 12.0 | 已修：`app/macos/Podfile` 的 `platform` 改 12.0，`post_install` 统一每个 pod，`Runner.xcodeproj` 三处 11.0 已改 12.0 |
| `brew install --cask flutter` 慢到只有几十 KB/s | cask 直连 `storage.googleapis.com` 拉 1.3 GB | 按 4.1 第 5 步手动从 `storage.flutter-io.cn` 下载解压 |
| `xattr -dr com.apple.quarantine` 输出一屏 `Permission denied` | SDK 的 `bin/cache/artifacts` 与 `.git/objects` 里有只读/已签名文件 | **正常现象，忽略**。这条命令本来就可以跳过 |
| `"flutter" 已损坏，无法打开` / Gatekeeper 拦截 | 手动解压的 SDK 带 quarantine 属性 | `xattr -dr com.apple.quarantine ~/development/flutter` |
| `flutter pub get` 卡在 pub.dev | 没设 `PUB_HOSTED_URL` | `export PUB_HOSTED_URL=https://pub.flutter-io.cn`（写进 `~/.zshrc`） |
| App 能开但连不上 SMB | macOS 沙盒拦 SMB 端口出站 | 确认 `Runner/*.entitlements` 里有 `com.apple.security.network.client` |

`pod install` 顺序不要搞反：**先 `build_apple_deps.py` 产出静态库，再 `flutter pub get`，最后 `flutter build macos`**。`flutter build` 内部会自动跑 `pod install`；单独手跑 `pod install` 必须先 `flutter pub get` 过，否则报 `Flutter/Flutter-generated.xcconfig must exist`。

## 5. Flutter Windows 桌面端
桌面端三块：Flutter 的 runner（`app/windows/`）、我方插件（`packages/lanplayer_video/`）、带 Win32 输出适配的 `lanplayer.dll`。**推荐一条命令：**

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2 flutter dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.py -Core -Clean
```

官方 `flutter build windows` 路径（装的是 VS 18 / 2026，需要下面两条辅助脚本各修一处坑）：

```powershell
python tool\fetch_deps.py zig ffmpeg libsmb2 flutter dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.py -Clean
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fix_plugin_links.py
python scripts\patch_flutter_tools.py
cd app
flutter pub get
flutter build windows --release
powershell -NoProfile -ExecutionPolicy Bypass -File ..\scripts\build_windows.py `
    -DeployTo build\windows\x64\runner\Release
```

| 环节 | 谁做 / 机制 | 坑与修法 |
|-|-|-|
| `build_windows_desktop.py` | ① `fix_plugin_links.py` 在 `app/windows/flutter/ephemeral/.plugin_symlinks/` 给 `lanplayer_video`、`path_provider_windows` 建 **junction**（不是符号链接）② `dart pub get`（环境变量重定向到 `.tools/`）③ VS 自带 cmake 以 `-G "Visual Studio 18 2026"` 生成、MSBuild 编 Release ④ `--target INSTALL` 把 `data/flutter_assets`、`icudtl.dat`、`flutter_windows.dll` 放到 exe 旁，再复制 `lanplayer.dll` 与 7 个 FFmpeg DLL | 另一条独立通道，不打补丁的机器也能用；产物在 `app\windows\out\build\x64-VisualStudio182026\`。只要内核时用 `scripts\build_windows.py`（Zig，无需 VS） |
| VS 18 generator | `flutter_tools/lib/src/windows/visual_studio.dart` 硬编码 `17 => 'Visual Studio 17 2022', _ => 'Visual Studio 16 2019'`，VS 18 落进 `_` 分支 | 报 `Generator Visual Studio 16 2019 could not find any instance of Visual Studio`；`patch_flutter_tools.py` 从 `cmake --help` 读出 `Visual Studio 18 2026` 注入显式分支并重建 `flutter_tools.snapshot`（幂等，重复运行只打印 already patched） |
| `flutter pub get` 建符号链接 | 普通令牌没有 `SeCreateSymbolicLink`（`errno 1314`） | junction 会被 `flutter_plugins.dart` 的 `if (link.existsSync()) continue;` 跳过，所以先用 `fix_plugin_links.py` 预建 |
| `-DeployTo` 必须执行 | `flutter build windows` 不会部署 `lanplayer.dll` 与 7 个 FFmpeg DLL | 漏了运行时报「找不到 FFmpeg」 |
| 插件头文件名 | `generated_*.{cc,cmake}` 的注册表按 `pluginClass` 的 snake_case 找头文件 | 必须是 `windows/include/lanplayer_video/lan_player_video_plugin.h`（注意 `lan_player` 拼写） |
| 纹理契约 | 插件注册 `flutter::PixelBufferTexture`；内核视频线程回调里调 `MarkTextureFrameAvailable`（线程安全），真正的 BGRA 拷贝发生在 raster 线程的 `CopyPixelBuffer` | 双缓冲 + `release_callback` 保证「引擎还在读的 buffer 不被覆盖」，两块都占用时丢帧而不是阻塞解码 |
| 状态目录 | `path_provider` 在 Windows 没有原生实现时插件内置 `plugins.flutter.io/path_provider` 兜底通道（`SHGetKnownFolderPath` + `GetFileVersionInfoW` 取 `CompanyName`/`ProductName`） | `servers.json` 落在 `%APPDATA%\<Company>\<Product>\lanplayer`，可用 `LANPLAYER_STATE_DIR` 覆盖 |

`--dart-define` 在这条通道上不走 `flutter build`，要用脚本参数写进 `generated_config.cmake` 的 `DART_DEFINES`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.py `
    -DartDefines "LANPLAYER_UI=add-server"
```

格式是**逗号分隔、每项各自 base64 的 `key=value`**（`encodeDartDefines()`，`packages/flutter_tools/lib/src/build_info.dart:1045`），不是 base64 的 JSON 数组。编错了不报错：构建成功、app 正常启动、define 悄悄丢失、`String.fromEnvironment` 拿到空串。确认看 `app\windows\flutter\ephemeral\generated_config.cmake`：

```
"DART_DEFINES=TEFOUExBWUVSX1VJPWFkZC1zZXJ2ZXI="   # base64("LANPLAYER_UI=add-server")
```

## 6. 桌面（无窗口：调试与自动检查）
```bash
cmake -B build -DLP_FFMPEG_ROOT=native/third_party/ffmpeg/desktop \
      -DLP_SMB2_ROOT=native/third_party/libsmb2
cmake --build build -j
./build/lp_smoke_test                       # 只验证加载与 ABI
./build/lp_smoke_test /path/to/file.mkv 5   # 软解 5 秒并打印位置
```

桌面走 `platform/stub`：无窗口、无声音，但有真实的音频拉取线程，可验证解封装、解码、时钟、字幕时序。Windows 上更完整的是 `scripts/build_windows.py` 产物（`lanplayer.dll` 带 GDI/waveOut，`lanplayer_preview.exe` 是原生界面）。

## 6.5 用 Visual Studio 打开仓库时，CMake 提示要不要启用
VS「打开文件夹」选中仓库根目录会弹出「检测到 CMakeLists.txt，是否启用 Visual Studio 的 CMake 支持？」——**选「不启用」**。Windows 上真正的内核构建是 `scripts/build_windows.py`（Zig，不走 CMake、不走 MSVC），**没有任何 CMake 目标会产出 `build/win-x64/lanplayer.dll`**。六个 `CMakeLists.txt` 各有主人，除 `native/`（手工 CMake / CI 的 Android、Apple 构建）外都靠 flutter_tools 或 Gradle 传参，VS 里单独配不了：`app/windows/`、`app/windows/flutter/`、`app/windows/runner/`（`flutter build windows` 传 `-DFLUTTER_ROOT=…`）、`packages/lanplayer_video/windows/`（由 `generated_plugins.cmake` include 的插件子目录）、`app/android/app/src/main/cpp/`（Gradle 的 `externalNativeBuild`）。

启用后坏在三处：

- `app/windows` 配不出来：它 `include(flutter/generated_config.cmake)`，那文件里是本机绝对路径（`file(TO_CMAKE_PATH "<仓库路径>\\.tools\\flutter-sdk" FLUTTER_ROOT)`），`.gitignore` 已排除，VS 独立配置时找不到 `FLUTTER_ROOT` 与 `generated_plugins.cmake`。
- `native/` 配得动但结果是错的：`native/CMakeLists.txt:61-65` 的分支是 `if(ANDROID) … elseif(APPLE) … else()`，Windows 落进 `else()` 即 `src/platform/stub/stub_platform.c`，没有渲染器、没有音频输出、没有 D3D11VA。
- 多出第二个构建树：VS 把产物放 `out/build/<preset>` 或仓库根的 `out`，与 `app\build\windows`、`build\win-x64` 都不重叠，FFmpeg 的 `avcodec-63.dll` 单个 114 MB，多一份就是几百 MB，且 `out/` 不在 `.gitignore` 里，有误提交风险（`.vs/` 已被排除）。

**A. 只当编辑器（最省事）**：菜单「文件 → 打开 → 文件夹」选仓库根目录，提示里选**不启用**；浏览、搜索、改代码、看 diff 都正常，构建走命令行（VS 里 `Ctrl+`` 开终端）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.py -Config Release -Core -Run
```

**B. 想用 VS 的 C++ 断点/内存窗口**：只在调试 Flutter runner 与插件桥时才值得，顺序不能反——先用 `flutter build windows --release` 生成 `ephemeral/generated_config.cmake`，再用「打开文件夹」指向 **`app\windows`**（不是仓库根目录），配置才能成功：

```powershell
cd app
flutter build windows --release
```

这条路径**只用于调试 UI 与插件桥**，内核仍是 `scripts/build_windows.py` 出的 `lanplayer.dll`（用 `-DeployTo` 拷到 exe 旁边）。VS 自带 `C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`，`build_windows_desktop.py` 用的就是它，A/B 两种都不缺 CMake。

## 7. 打安装包
两个平台各一条命令，产物落在 `dist/`（已在 `.gitignore` 里，属发布资产而非源码）。

### 7.1 Windows（NSIS）
```powershell
python tool\fetch_deps.py nsis        # 只装 NSIS 3.10 到 .tools\nsis（约 2.2 MB）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_installer.py -Version 0.1.0
# -> dist\LanPlayer-0.1.0-windows-x64-setup.exe
```

脚本四步，任何一步失败都 `exit 1` 而不是留下半个包：① 校验 `app\build\windows\x64\runner\Release` 里有 `lanplayer.exe`、`lanplayer.dll`、`avcodec-63.dll`、`avformat-63.dll`（缺就提示先跑 `flutter build windows --release` 与 `scripts\build_windows.py -DeployTo …`）；② 暂存到 `dist\stage\windows`：10 个 exe/dll（逐个列名，与 `.nsi` 的 `File` 一一对应）+ `data\`（`app.so`、`icudtl.dat`、`flutter_assets`）+ 6 个 `Microsoft.VC145.CRT` 运行库（从 vswhere 定位 VS 的 Redist 目录）；③ `makensis /DAPP_VERSION=… /DSTAGE=… /DOUTFILE=… /DAPP_ICON=…`；④ 打印大小与 SHA256，默认清掉暂存目录（`-KeepStage` 保留，`-Open` 打开 `dist`）。`avdevice-63.dll`（4.9 MB）**故意不打包**：`dumpbin /DEPENDENTS` 显示没有模块依赖它，核心也从不调 `avdevice_*`。

安装行为（`scripts/windows/installer.nsi`）：

| 项 | 值 |
|-|-|
| 安装位置 | `%LOCALAPPDATA%\Programs\LanPlayer` |
| 权限 | `RequestExecutionLevel user`，**不弹 UAC**，不写 `Program Files` |
| 页面 | 欢迎 → 许可（`LICENSE`）→ 组件（核心必装 / 快捷方式 / 文件关联可选）→ 目录 → 安装 → 完成 |
| 语言 | 简体中文 + English（NSIS 自带 `SimpChinese.nlf`） |
| 卸载 | 删全部文件与快捷方式、清两类注册表键；用户数据由选项页的勾选框决定（默认保留，静默卸载要 `/PURGE`）。`PurgeUserData` 宏覆盖四处候选目录：`%APPDATA%\<Company>\<Product>\lanplayer`、`%LOCALAPPDATA%\lanplayer`、`<安装目录>\state`、`%TEMP%\lanplayer`；前两层的公司/产品目录用不带 `/r` 的 `RMDir` 收尾，不为空时不动 |
| `.nsi` 编码 | 必须 **UTF-8 with BOM**，无 BOM 时 `makensis` 报 `Bad text encoding: scripts\windows\installer.nsi:1`（`check_installers()` 会检查） |
| 临时目录 | `makensis` 往 `%TEMP%` 写临时文件，被拒时表现为 `Internal compiler error #12345: error creating mmap`（后面还跟着一个字节数）；脚本已把 `TMP`/`TEMP` 重定向到 `.tools\tmp` |
| 脚本编码 | 脚本一律 UTF-8。旧 PowerShell 版本曾要求「无 BOM 就纯 ASCII」——那是 PS 5.1 按 cp936 解码的坑；改成 Python 后这条约束消失，`check_all` 只要求能被 UTF-8 解码 |

静默安装/卸载：

```cmd
dist\LanPlayer-0.1.0-windows-x64-setup.exe /S /D=D:\some\dir
D:\some\dir\uninstall.exe /S
```

**覆盖升级不要求先手动卸载**：`lanplayer.exe` 与 13 个 DLL 运行时是已映射映像，Windows 不允许覆盖正在运行的映像（文件系统规则，不是安装器 bug），所以 `installer.nsi` 有 `!macro StopRunningApp`，在 `Section "LanPlayer 主程序"` 与 `Section "Uninstall"` 各插一次，分三步：**先礼**——`taskkill /IM lanplayer.exe`（**不带 `/F`**，等于发 `WM_CLOSE`，走正常退出、设置能安稳写盘），再用 `tasklist /FI "IMAGENAME eq lanplayer.exe" /NH | findstr` 每 500 ms 探一次、最多 10 次，5 秒还没退才 `taskkill /F`；**后兵**——用 `FileOpen` 追加模式探 `$INSTDIR\lanplayer.dll` 是否可写（被映射的映像既不能改也不能删，打开就失败），写不进去说明还有进程映射着它，于是枚举 `$INSTDIR\*.exe` 逐个 `taskkill /F /IM`；**绕过**——再等 3 秒仍不可写，就把占用中的 `lanplayer.dll` 与 `lanplayer.exe` 改名成 `<名>.old`，让 `File` 在原文件名上写出新文件，装完再尽力删掉 `.old`。最后这一步是关键：Windows 不允许删除或覆盖已映射的映像文件（`os.remove` 报拒绝访问，连所在目录都改不了名），但**允许重命名**，所以不必等占用方退出。`.old` 当场删不掉是正常的（映像还在映射），安装器用 `Delete /REBOOTOK` 把它登记给下次重启，下一次安装或卸载开头的 `Delete` 也会顺手清掉，不会越积越多；卸载后目录里只剩这样一个待重启删除的文件，注册表与其余文件都已清干净。没有这一步，交互安装会弹「无法打开要写入的文件」、静默安装更糟 —— 退出码 0 却把写不进去的文件静默跳过，装完新旧 DLL 混搭。卸载段同样处理：`Delete` 对占用文件是静默失败，注册表却已删干净，用户以为卸载成功，下次安装继续撞同一堵墙。第二步不能省：把 exe 复制成别的名字再运行，`tasklist /FI "IMAGENAME eq ..."` 查不到，DLL 仍被映射，`File` 会静默跳过它，装完就是新 exe 配旧 DLL。别用 `taskkill` 或 `tasklist` 的退出码判断「在不在跑」：不带 `/F` 的 `taskkill` 对收不到 `WM_CLOSE` 的进程返回错误码而进程还活着；`tasklist` 无匹配时也返回 0。也别改成 `tasklist /M` 或 `taskkill /FI "MODULES eq ..."`——它们要查 64 位模块表，而安装器引擎是 32 位，在 `nsExec` 里永不返回（同样的命令在 cmd 里 0.3 秒就结束）。`InstallDirRegKey HKCU "Software\LanPlayer" "InstallDir"` 也必须保留，否则覆盖升级会装出第二份。

四个验证脚本（都属 `REQUIRED`，check_all 会盯着）：

```powershell
python scripts\verify_windows_upgrade.py          # 旧版运行中 -> 装新版
python scripts\verify_windows_uninstall.py        # 应用运行中 -> 卸载
python scripts\verify_windows_locked_upgrade.py   # 装新版时 DLL 被映射，杀不掉
python scripts\verify_windows_locked_uninstall.py # 卸载时 DLL 被映射，杀不掉
```

`verify_windows_locked_upgrade.py` 专门盯「改名让开」这一步：它让一个把 `lanplayer.dll` 作为镜像映射的进程把文件占住（既不在 `$INSTDIR` 里也不叫 `lanplayer.exe`，所以杀不到），再装新包，要求 `lanplayer.dll` 的哈希确实换掉、且第二次安装能把上一轮留下的 `.old` 清掉；同一场景装旧包必须失败 —— 这就是负对照。少了这一步，安装器要么弹「无法打开要写入的文件」，要么静默留着旧 DLL。`verify_windows_locked_uninstall.py` 是它在卸载侧的对应物：同样占住 DLL 再跑 `uninstall.exe /S`，要求注册表清空、目录里只剩待重启删除的 `.old`、占用方退出后重装不留残留；加 `--expect-fail` 跑旧包，则要求它真的留下文件，否则说明断言没在测东西。

四个都装到 `D:\lp-upgrade-test` / `D:\lp-uninstall-test` / `D:\lp-locked-test` / `D:\lp-locked-uninstall` 这类 scratch 目录，跑完恢复注册表与快捷方式，不动真实安装；它们做**正负对照**：把宏拆掉的安装器必须让脚本报失败，否则说明断言没在测东西。`verify_windows_uninstall.py` 另外验三件事：静默卸载保留用户数据、`/S /PURGE` 删掉用户数据、删完连 `%APPDATA%` 下的公司目录一并收尾；它会把真实状态目录先挪走再放回，不会动开发机上的配置。跑时注意两点：**先把安装包复制到 `%TEMP%` 再执行**（仓库里的文件带 Low 完整性标签，复制出去跑是为了不弄脏 `dist\`）；**别用异步启动加轮询 `HasExited` 的写法**（在本机会死锁），脚本内部用同步的 `cmd /c "<setup>" /S`。四个脚本在 Git Bash 与 PowerShell 里都能跑，并且不依赖 Windows 自带的 `find`（`installer.nsi` 用 `findstr`，Python 版直接读 `tasklist` 输出）。

### 7.2 macOS（dmg）
```bash
# 前置：scripts/build_apple_deps.py 与 flutter build macos --release 都已完成
VERSION=0.1.0 python3 scripts/build_macos_dmg.py
# -> dist/LanPlayer-0.1.0-macos-arm64.dmg
```

脚本流程：检查 `.app` → `ditto` 拷到暂存目录 → `ln -s /Applications` → `codesign --verify --deep --strict` → `hdiutil create -ov -format UDZO -imagekey zlib-level=9` → `hdiutil verify` → 打印 SHA256。两个坑（`check_installers()` 也盯着）：**必须用 `ditto` 而不是 `cp -R`**（`cp -R` 丢扩展属性与代码签名，`codesign --verify` 直接失败）；**不要在同目录建小写别名**（APFS 默认大小写不敏感，`LanPlayer.app` 与 `lanplayer.app` 是同一目录，随后的清理会把刚拷好的 app 删掉，dmg 只有 11 KB 且里面是空的就这原因）。签名默认 ad-hoc（`codesign -dv` 显示 `Signature=adhoc`），自用足够；**分发需要 Developer ID 证书 + 公证**，否则对方打开会被 Gatekeeper 拦（`已损坏，无法打开` / `无法验证开发者`）。

### 7.3 版本号来源与覆盖升级
版本号只有一个来源：`app/pubspec.yaml` 的 `version:`。`scripts\build_windows_desktop.py` 用正则读出它写进 `generated_config.cmake` 的 `FLUTTER_VERSION`，`Runner.rc` 再把它变成 exe 的 `FileVersion`/`ProductVersion`；`build_windows_installer.py` 的 `--version`、`build_macos_dmg.py` 与 `build_android_apk.py` 的 `VERSION` 留空时同样取它。所以升版本只改 pubspec，别去改脚本里的字面量。

Windows 包必须先 `flutter build windows --release`（或 `scripts\build_windows_desktop.py`）把产物放到 `app/build/windows/x64/runner/Release/`——**安装脚本只认这个路径**，再用 `build_windows.py --deploy-to` 把新内核 DLL 覆盖进去，否则打进去的仍是旧 DLL。macOS 先 `flutter build macos --release` 再 `python3 scripts/build_macos_dmg.py`；Android 先 `python3 scripts/build_android_deps.py arm64-v8a` 再 `python3 scripts/build_android_apk.py`。三个打包脚本都要能在 `PATH` 里找到 `flutter`，找不到时 dmg 会安静地把上一次的 `.app` 打进去。

**覆盖升级**：装新版不用先手动卸载。`scripts/windows/installer.nsi` 的 `StopRunningApp` 宏在安装段与卸载段各调一次：先 `taskkill`（不带 `/F`，等于发 WM_CLOSE），轮询 5 秒不退才强杀；强杀完还是写不进 `lanplayer.dll`，就把 `$INSTDIR\*.exe` 逐个按名强杀（改名副本也躲不掉），最后把仍被占用的 `lanplayer.dll` / `lanplayer.exe` 改名成 `.old` 让 `File` 写出新文件。判断「在不在跑」必须用 `tasklist | findstr`，**不能用 `find`** —— 某些 shell 的 `PATH` 里 GNU find 排在 System32 前面，它不认 `/FI`、`/I`，退出码非 0，宏会把「还在跑」误判成「没在跑」。回归用 `scripts\verify_windows_upgrade.py` / `verify_windows_uninstall.py`，两个脚本都装到临时目录、跑完恢复注册表与快捷方式，不动真实安装。

静默安装到自定义目录时 `/D=` 必须是**最后一个参数**且不能带引号；PowerShell 里更稳的写法是 `Start-Process -ArgumentList '/S','/D=D:\path' -Wait`。

### 7.4 构建后自检
```bash
python tool/check_all.py            # 一把梭：C 语法/符号、Dart 解析、原生冒烟、Dart 测试
cd app && flutter analyze && flutter test # 有 Flutter SDK 时的完整检查
```

`tool/check_all.py` 会自动跳过缺失的工具链（没有 Flutter 就不做 UI 检查），并顺带跑一遍 Windows 上已编译的 `build\win-x64\lp_smoke_test.exe`。

**Windows 上 `flutter analyze` / `flutter test` 要包一层**：`%APPDATA%` 与 `%LOCALAPPDATA%` 不可写时 flutter_tools 会失败在

```
Error: Flutter failed to write to a file at "C:\Users\...\AppData\Roaming\.flutter_tool_state"
```

（`analyze` 还会额外在 `%LOCALAPPDATA%\.dartServer` 上报 `PathAccessException`）。`scripts/run_flutter_tests.py` 把 `TMP`/`TEMP`/`APPDATA`/`PUB_CACHE` 和 `LOCALAPPDATA` 重定向到仓库内的 `.tools/`：

```bash
./scripts/run_flutter_tests.py              # 等价于 flutter test
./scripts/run_flutter_tests.py analyze      # 透传给任意 flutter 子命令
```

哪些中间产物可以安全删除（都不在 git 里，删了不影响源码）：

| 路径 | 删掉的代价 | 怎么重建 |
|-|-|-|
| `build\media\` | 测试素材没了；`check_all.py` 的硬解一项自动跳过 | `python scripts\make_test_media.py` |
| `build\win-x64\` | 内核 DLL 与 4 个测试 exe 没了；原生冒烟/硬解两项自动跳过 | `powershell -File scripts\build_windows.py` |
| `native\third_party\` | 静态库/动态库全没了，任何平台都编不动 | `scripts\build_windows.py` 或 `SLICES=<family> python3 scripts/build_apple_deps.py` |
| `app\build\`、`app\windows\out\`、`app\windows\flutter\ephemeral\` | Flutter 构建缓存与 CMake 中间件 | 重跑 `flutter build windows`（CMake 会重新生成 `ephemeral`） |
| `app\.dart_tool\flutter_build\` | 编译缓存；`package_config.json` 会留着 | 重跑一次 `flutter build` |
| `dist\` | 两个安装包 | `scripts\build_windows_installer.py` / `scripts\build_macos_dmg.py` |

**不能删**：`.tools\`（工具链本体 2.7 GB，只能重新 `fetch_deps.py` 下载）、`.tools\flutter-sdk\.git`（Flutter 工具会校验，删了报「不是 GitHub 仓库的克隆」）、`.tools\flutter-sdk\bin\mingit`（这台机器上唯一可用的 git）。

## 8. 常见问题
|现象|原因 / 处理|
|-|-|
|`libavformat.so not found`|只打了 `liblanplayer.so`，FFmpeg `.so` 没随 APK 打包（检查 `abiFilters` 与 `jniLibs`）|
|硬解直接回退软解|`lp_player_set_surface` 在 `open` 之后才调用；先创建纹理再 open（UI 已是这个顺序）|
|4K 卡顿|APK 没开 `largeHeap`，或 SMB 读太慢：调大 `readahead_kb` 与 `timeout_ms`|
|10-bit H.264（Hi10P / High 10）片源画面不动、进度条照走|正常：三端硬解都不实现这个 profile，`profile_needs_software()` 会把它挡在门外改走软解（日志里一条 `profile 110 is decoded better in software`）。别去「修」这条 WARN|
|10-bit HEVC（Main10）在 Mac / Android 上画面不动|正常，同样是 `profile_needs_software()` 挡下来走软解（`profile 2 is decoded better in software`）。**Windows 例外**：D3D11VA 解 10-bit HEVC 是满帧的，那边故意不拦，改这一项时别三端照抄|
|iOS 链接不到 `lp_*`|漏了 Bridging Header 或静态库没加到 Link Binary With Libraries|
|字幕乱码|不是 UTF-8/UTF-16。Windows 上内核用 `MultiByteToWideChar` 依次试 GB18030/GBK/Big5/Shift-JIS/CP949；Android 需要 iconv 或先转 UTF-8|
|`Building with plugins requires symlink support`|Windows 未开「开发者模式」或令牌无 `SeCreateSymbolicLink`：用 `scripts\fix_plugin_links.py` 建 junction，或直接 `scripts\build_windows_desktop.py`|
|`Generator Visual Studio 16 2019 could not find any instance`|flutter_tools 只认 2019/2022：先跑 `scripts\patch_flutter_tools.py`，或用 `scripts\build_windows_desktop.py`|
|`flutter build windows` 找不到 Visual Studio|Flutter 桌面只认 MSVC，需要「使用 C++ 的桌面开发」工作负载|
|VS 提示「是否启用 CMake 支持」|选**不启用**：六个 `CMakeLists.txt` 分别归 flutter_tools / Gradle / 插件子目录，Windows 内核不走 CMake（见 6.5）|
|VS 里配 `app/windows` 报找不到 `FLUTTER_ROOT`|`ephemeral/generated_config.cmake` 还没生成：先跑一次 `flutter build windows`，再打开 `app\windows`|
|exe 启动即退出、无窗口|只编了 `lanplayer` 目标没跑 `INSTALL`：`data/flutter_assets`、`icudtl.dat` 不在 exe 旁。重跑 `build_windows_desktop.py`|
|运行时报 `lanplayer.dll not found`|DLL 不在 exe 旁：用 `-DeployTo <输出目录>`，或设 `LANPLAYER_CORE=<DLL 所在目录>`|
|画面偏蓝（红变蓝、蓝变红）|通道顺序：内核出 **BGRA**，Flutter 的 `FlutterDesktopPixelBuffer` 无格式字段、引擎一律按 **RGBA8888** 读。插件 `VideoTexture::Copy()` 必须调 `lp_bgra_to_rgba()`（`packages/lanplayer_video/windows/include/lanplayer_video/pixel_swizzle.h`）；`lp_win32_texture_test.exe ... --expect-red` 会断言这件事|
|服务器列表重启后消失|状态目录不可写：设 `LANPLAYER_STATE_DIR=<可写目录>`；正常应落在 `%APPDATA%\<Company>\<Product>\lanplayer`|
|有声音但画面黑|`attachPlayer` 在 `open` 之后才调用；插件必须先拿到 player 指针|
|硬解没生效（一直 `hw=software`）|`lp_hw_decoder_available()` 缓存首次探测结果：驱动不支持 D3D11VA 就永久回退。用 `lp_hw_decode_test.exe <视频>` 看真实解码器名；`--selftest` 默认钉住 `sw`，要看硬解得显式 `--hw auto`|
|老显卡 / 虚拟机里 D3D11 设备建不出来|`av_hwdevice_ctx_create(AV_HWDEVICE_TYPE_D3D11VA)` 失败即走软件路径，不影响播放；WARP 软件 D3D 设备也能吃 D3D11VA，只是没有解码加速|
