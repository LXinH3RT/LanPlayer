# 内核源文件清单的唯一定义处。
#
# 以前同一份清单被抄在三个地方（native/CMakeLists.txt 的 LP_CORE_SOURCES、
# scripts/build_windows.py 的 CORE_SOURCES、scripts/build_apple_deps.py 的
# CORE_SOURCES），新增一个 .c 要改三处，漏改的后果是「本地编得过、CI 里符号
# 找不到」或者反过来。现在只在这里写一次：
#
#   * CMake 直接 include 本文件；
#   * scripts/build_windows.py 与 scripts/build_apple_deps.py 通过
#     tool/native_sources.py 解析本文件（同一个解析函数，不是第二次抄写）。
#
# 路径一律相对于 native/。平台无关的核心放在 LP_CORE_SOURCES，各平台适配层
# 放在 LP_PLATFORM_<平台>_SOURCES —— 同一平台只能有其中一份进链接，因为
# stub / apple / android / win32 各自定义同一组 lp_platform_* 符号。

set(LP_CORE_SOURCES
    src/util/lp_str.c
    src/util/lp_log.c
    src/core/queue.c
    src/core/audio_ring.c
    src/core/nal.c
    src/core/demux.c
    src/core/video.c
    src/core/audio.c
    src/core/subtitle.c
    src/core/submatch.c
    src/core/thumb.c
    src/core/player.c
    src/source/url.c
    src/source/io.c
    src/source/smb.c
    src/source/file.c
)

# CI 用的空输出后端：没有窗口、没有声卡，只保证符号齐全、线程模型可跑。
set(LP_PLATFORM_STUB_SOURCES
    src/platform/stub/stub_platform.c
)

set(LP_PLATFORM_ANDROID_SOURCES
    src/platform/android/media_codec_decoder.c
    src/platform/android/egl_renderer.c
    src/platform/android/aaudio_sink.c
    src/platform/android/jni_bridge.c
)

# Apple 必须整套给：VideoToolbox 解码、CoreAudio 输出、以及把 CVPixelBuffer
# 画进 Flutter 纹理的适配层，少一个都是链接错误（不是运行期降级）。
set(LP_PLATFORM_APPLE_SOURCES
    src/platform/apple/videotoolbox_decoder.c
    src/platform/apple/coreaudio_sink.c
    src/platform/apple/apple_texture.c
)

# win32_platform.c 是框架适配层（渲染 + WASAPI）；D3D11VA 解码器单独一个
# 编译单元，因为只有它碰 libavcodec 的硬件路径；d3d11_output.c 持有 D3D11
# 设备与共享 BGRA 表面。
set(LP_PLATFORM_WIN32_SOURCES
    src/platform/win32/win32_platform.c
    src/platform/win32/d3d11va_decoder.c
    src/platform/win32/d3d11_output.c
)

# 只在 Windows 桌面构建里用的可执行程序源，不进 lanplayer.dll。单独一组是
# 因为构建脚本按位置取对象文件（DLL 少它一个，预览窗口多它一个）。
set(LP_TOOL_WIN32_SOURCES
    src/app/lp_preview.c
)
