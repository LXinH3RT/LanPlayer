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

# 解析仓库根目录。__dir__ 可能是符号链接路径（Flutter 把插件挂到
# ephemeral/.symlinks/plugins/ 下），先 File.realpath 还原成
# packages/lanplayer_core/macos 的真实路径，再向上三级得到仓库根。
def lanplayer_repo_root(spec_dir)
  real = File.realpath(spec_dir)
  root = File.expand_path('../../..', real)
  marker = File.join(root, 'native', 'src', 'core', 'player.c')
  unless File.exist?(marker)
    raise "lanplayer_core: 从 #{real} 推出的仓库根 #{root} 里没有 native/src/core/player.c"
  end

  root
end

LP_ROOT = lanplayer_repo_root(__dir__)
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
