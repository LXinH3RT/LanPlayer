# LanPlayer C 内核的 iOS / iPadOS podspec。
#
# 这个 pod 不含任何 Objective-C / Swift 源码，只做三件事：
#   1. 让 Flutter 知道 iOS 上有这么个原生依赖，从而把它写进 Podfile 的 pod 列表；
#   2. 给 Runner 加头文件搜索路径（Swift 桥接头要 #include "lanplayer/lp_player.h"）；
#   3. 给 Runner 加库搜索路径和链接参数（liblanplayer.a + FFmpeg + libsmb2）。
#
# 为什么不用 source_files 让 CocoaPods 去编 C：
#   native/src 在 pod 目录之外，Flutter 还会把插件以符号链接挂到
#   app/ios/Flutter/ephemeral/.symlinks/plugins/ 下，让 CocoaPods 跨符号链接
#   去 glob 并编译外部源码很容易出各种边角问题；而 scripts/build_apple_deps.sh
#   本来就要在 Mac 上跑（FFmpeg / libsmb2 只能现场编），顺手把 C 内核也编成
#   liblanplayer.a 只是多十几行 shell，链路更短、更好排查。
#
# 所以在 Mac 上的正确顺序是：
#   scripts/build_apple_deps.sh        # 产出 native/third_party/**，含 liblanplayer.a
#   flutter pub get
#   flutter build ios --release
# 缺 liblanplayer.a 时链接会报 "library not found for -llanplayer"，看到这句
# 就回去跑第一个命令。

# 从 podspec 所在目录开始向上找仓库根（含 native/src/core/player.c 的那一层）。
#
# 两个坑要一起绕：
#   1. Flutter 把插件挂到 app/ios/Flutter/ephemeral/.symlinks/plugins/ 下再让
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
    raise "lanplayer_core: 从 #{base} 向上找不到仓库根（应含 native/src/core/player.c），请确认 podspec 在 <repo>/packages/lanplayer_core/ios/ 下。"
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

  s.ios.deployment_target = '13.0'
  s.ios.dependency 'Flutter'

  # 内核必须静态进 app 二进制：Dart 侧在 iOS 上用 DynamicLibrary.process()
  # （见 app/lib/core/bindings.dart），不会去 dlopen 一个 .dylib。
  s.static_framework = true

  # 让 pod install 不要清掉这些目录（它们在 pod 目录之外，但必须存活）。
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

  # Runner 侧也要能 #include "lanplayer/lp_player.h"（Swift 桥接头用），
  # 而且最终链接发生在 Runner 上，所以这些设置必须同时给 host target。
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
    # 顺序有讲究：依赖方在前、被依赖方在后。avformat 依赖 avcodec，
    # avcodec/swscale/swresample 依赖 avutil，avfilter 依赖 avformat+avutil。
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

  # FFmpeg 的 mov/mp4 解封装与部分编码用 zlib / bzip2 / lzma，
  # 字幕转码用 iconv；解码与音频输出走 VideoToolbox / AudioToolbox。
  s.libraries = 'z', 'bz2', 'lzma', 'iconv'
  s.frameworks = 'VideoToolbox', 'CoreMedia', 'CoreVideo',
                 'AudioToolbox', 'CoreFoundation', 'Security'
end
