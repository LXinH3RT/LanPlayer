# LanPlayer C 内核的 macOS podspec。
#
# 这个 pod 不含任何 Objective-C / Swift 源码，只做三件事：
#   1. 让 Flutter 把 lanplayer_core 写进 macos/Podfile 的 pod 列表；
#   2. 给 Runner 加头文件搜索路径（Swift 桥接头要 #include "lanplayer/lp_player.h"）；
#   3. 给 Runner 加库搜索路径和链接参数（liblanplayer.a + FFmpeg + libsmb2）。
#
# 为什么不在 pod 里直接编 C：见 ios/lanplayer_core.podspec 顶部的说明——
# C 内核由 scripts/build_apple_deps.sh 一起编成 liblanplayer.a，链路更短。
#
# 在 Mac 上的正确顺序：
#   scripts/build_apple_deps.sh        # 产出 native/third_party/**，含 liblanplayer.a
#   flutter pub get
#   flutter build macos --release
# 缺 liblanplayer.a 时链接报 "library not found for -llanplayer"。

# 从 podspec 所在目录开始向上找仓库根（含 native/src/core/player.c 的那一层）。
#
# 两个坑要一起绕：
#   1. Flutter 把插件挂到 app/macos/Flutter/ephemeral/.symlinks/plugins/ 下再让
#      CocoaPods 去读，此时 __dir__ 是符号链接路径，沿它向上永远走不到仓库根
#      （native/ 在真实路径的三级之上）。所以先 File.realpath 还原。
#   2. CocoaPods 用 eval 读 podspec 时，相对路径的 __dir__ 可能退化成 "."。
#      所以 realpath 失败就退回 File.expand_path，再按文件标记向上搜索。
#
# 另外这里【不能】写 `def lanplayer_repo_root(...)`：CocoaPods 1.16 起把 podspec
# 放在 `module Pod` 的作用域里 eval，顶层 def 会变成 Pod 模块的实例方法，调用时
# 直接报 undefined method 'lanplayer_repo_root' for module Pod
# （CocoaPods 1.17 + Ruby 4.0 上实测）。
LP_ROOT = begin
  base = begin
    File.realpath(__dir__)
  rescue StandardError
    File.expand_path(__dir__)
  end
  dir = base
  found = nil
  loop do
    if File.exist?(File.join(dir, 'native', 'src', 'core', 'player.c'))
      found = dir
      break
    end

    parent = File.dirname(dir)
    break if parent == dir
    dir = parent
  end
  unless found
    raise "lanplayer_core: 从 #{base} 向上找不到仓库根（应含 native/src/core/player.c），请确认 podspec 在 <repo>/packages/lanplayer_core/macos/ 下。"
  end

  found
end
LP_NATIVE = File.join(LP_ROOT, 'native')
LP_THIRD = File.join(LP_NATIVE, 'third_party')
LP_FFMPEG_LIB = File.join(LP_THIRD, 'ffmpeg', 'apple', 'lib')
LP_FFMPEG_INC = File.join(LP_THIRD, 'ffmpeg', 'apple', 'include')
LP_SMB2_LIB = File.join(LP_THIRD, 'libsmb2', 'apple', 'lib')
LP_SMB2_INC = File.join(LP_THIRD, 'libsmb2', 'apple', 'include')
LP_CORE_LIB = File.join(LP_THIRD, 'lanplayer', 'apple', 'lib')

Pod::Spec.new do |s|
  s.name = 'lanplayer_core'
  s.version = '0.1.0'
  s.summary = 'LanPlayer 的 C 内核：FFmpeg 解码 + libsmb2 访问 SMB 共享。'
  s.description = <<-DESC
    LanPlayer 的跨平台 C 内核，通过 dart:ffi 暴露给 Flutter。
    本 pod 只有预编译好的静态库与头文件，没有 Objective-C / Swift 源码。
  DESC
  s.homepage = 'https://github.com/lanplayer/lanplayer'
  s.license = { :type => 'MIT', :text => 'Copyright (c) LanPlayer contributors' }
  s.author = { 'LanPlayer' => 'lanplayer@example.com' }
  s.source = { :path => '.' }

  # 内核用 arm64 与 x86_64 都在编，最低系统跟着 scripts/build_apple_deps.sh
  # 的 MIN_MACOS 走（脚本里是 11.0）。
  s.osx.deployment_target = '11.0'
  s.osx.dependency 'FlutterMacOS'

  # 必须静态进 app 二进制：Dart 侧在 macOS 上用 DynamicLibrary.process()
  # （见 app/lib/core/bindings.dart），不会去 dlopen 一个 .dylib。
  s.static_framework = true

  s.preserve_paths = [
    File.join(LP_NATIVE, 'include', '**', '*.h'),
    File.join(LP_CORE_LIB, '**', '*.a'),
  ]

  # Classes/ 里只有一个空的锚点 .m：它 #include "lanplayer/lp_player.h"，
  # 用来在 pod 构建阶段就验证 HEADER_SEARCH_PATHS 是否正确（见该文件注释）。
  # 真正的 C 实现来自下面 OTHER_LDFLAGS 里链接的 liblanplayer.a。
  s.source_files = 'Classes/**/*.{h,m}'

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '"$(inherited)"',
      %("#{File.join(LP_NATIVE, 'include')}"),
      %("#{File.join(LP_NATIVE, 'src')}"),
      %("#{File.join(LP_NATIVE, 'src', 'source')}"),
      %("#{LP_FFMPEG_INC}"),
      %("#{LP_SMB2_INC}"),
    ].join(' '),
  }

  s.user_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '"$(inherited)"',
      %("#{File.join(LP_NATIVE, 'include')}"),
    ].join(' '),
    'LIBRARY_SEARCH_PATHS' => [
      '"$(inherited)"',
      %("#{LP_CORE_LIB}"),
      %("#{LP_FFMPEG_LIB}"),
      %("#{LP_SMB2_LIB}"),
    ].join(' '),
    # 顺序有讲究：依赖方在前、被依赖方在后。
    'OTHER_LDFLAGS' => [
      '"$(inherited)"',
      '-llanplayer',
      '-lavformat', '-lavcodec', '-lswresample',
      '-lavfilter', '-lswscale', '-lavutil',
      '-lsmb2',
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS' => [
      '"$(inherited)"',
      'LP_PLATFORM_APPLE=1',
      'LP_HAVE_ICONV=1',
      'LP_HAVE_SMB2=1',
      'LP_ENABLE_HTTP=1',
    ].join(' '),
  }

  s.libraries = 'z', 'bz2', 'lzma', 'iconv'
  s.frameworks = 'VideoToolbox', 'CoreMedia', 'CoreVideo',
                 'AudioToolbox', 'CoreFoundation', 'Security'
end
