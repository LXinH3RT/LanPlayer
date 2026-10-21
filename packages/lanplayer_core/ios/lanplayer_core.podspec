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

# C 内核对外导出的全部函数（对应 native/include/lanplayer/*.h 里的 LP_EXPORT）。
# 这些符号要靠 ld 的 -u 强引用住，否则 dead-strip 会把它们当死代码删掉，
# Dart 的 dlsym 就取不到（详见下面 user_target_xcconfig 里的注释）。
# 新增/删除导出函数时，这里和 tool/check_all.py 的守护要一起改。
LP_EXPORTED_SYMBOLS = %w[
  lp_abi_version
  lp_log_get_level
  lp_log_set_callback
  lp_log_set_level
  lp_player_add_subtitle
  lp_player_close
  lp_player_copy_pixel_buffer
  lp_player_create
  lp_player_destroy
  lp_player_get_duration
  lp_player_get_media_info
  lp_player_get_option
  lp_player_get_position
  lp_player_get_speed
  lp_player_get_state
  lp_player_install_frame_callback
  lp_player_open
  lp_player_pause
  lp_player_play
  lp_player_seek
  lp_player_select_track
  lp_player_set_event_callback
  lp_player_set_mute
  lp_player_set_option
  lp_player_set_scale_mode
  lp_player_set_speed
  lp_player_set_subtitle_delay
  lp_player_set_surface
  lp_player_set_surface_size
  lp_player_set_volume
  lp_player_stop
  lp_source_last_error
  lp_source_list
  lp_source_options_default
  lp_source_options_parse
  lp_source_probe
  lp_source_schemes
  lp_string_free
  lp_url_normalize
].freeze

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
  # source 的主键只能是 git / hg / http / svn；{ :path => '.' } 会得到
  #   WARN | keys: Missing primary key for `source` attribute.
  # 这个 pod 由本地 path 依赖引入（见 app/ios/Podfile），source 只为通过校验。
  s.source = { :git => 'https://github.com/LXinH3RT/LanPlayer.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.ios.dependency 'Flutter'

  # 内核必须静态进 app 二进制：Dart 侧在 iOS 上用 DynamicLibrary.process()
  # （见 app/lib/core/bindings.dart），不会去 dlopen 一个 .dylib。
  s.static_framework = true

  # 这里【不要】写 preserve_paths。CocoaPods 校验要求每条 pattern 都是相对路径：
  #   ERROR | File Patterns: File patterns must be relative and cannot start with
  #           a slash (preserve_paths).
  # 我们的头文件与 .a 都在 pod 目录之外（native/ 下），CocoaPods 本来也不会删它们，
  # 这条声明没有作用。让链接器找到它们的是下面 user_target_xcconfig 里的
  # HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS。

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
    #
    # 两个坑叠在一起，都必须处理，否则 app 能编出来但一开视频就崩：
    #
    # 坑 1：ld 默认只从 .a 里抽「被静态引用到的」目标文件。Dart 侧
    #   app/lib/core/bindings.dart 在 iOS 上走 DynamicLibrary.process()，
    #   靠 dlsym(RTLD_DEFAULT, "lp_xxx") 取符号，链接器看不见这种引用。
    #   Swift 桥接头只直接调了两个函数，其余 lp_* 会被整体丢弃。
    #   修法：-Wl,-force_load,<归档> 让整个归档无条件进链接。
    #
    # 坑 2：归档进来了，ld 的 dead-strip 阶段仍按「有没有静态引用」删代码，
    #   而 Runner target 的 pbxproj 把 DEAD_CODE_STRIPPING 写死成 YES
    #   （target 级设置盖过 podspec 从 xcconfig 注入的值，实测改无效）。
    #   改用 -Wl,-u,_lp_xxx 把每个导出符号声明成外部引用，
    #   dead-strip 就不会动它们，也不必关掉整个工程的死代码裁剪。
    #   实测 macOS 27 / Xcode 27.1 / ld 1115.7.2：只加 -force_load 时
    #   nm -g 只有 2 个 T _lp_ 符号；补上 -u 后 40 个全部保留。
    'OTHER_LDFLAGS' => [
      '"$(inherited)"',
      %("-Wl,-force_load,#{File.join(LP_CORE_LIB, 'liblanplayer.a')}"),
      *LP_EXPORTED_SYMBOLS.map { |sym| %("-Wl,-u,_#{sym}") },
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
