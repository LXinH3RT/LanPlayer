cmake_minimum_required(VERSION 3.20)
project(lanplayer_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# Inputs
#
#   LP_FFMPEG_ROOT  directory that contains include/ lib/ (mobile) or the cmake
#                   config files (desktop).  Defaults to
#                   third_party/ffmpeg/<abi> for a manual drop-in.
#   LP_SMB2_ROOT    directory that contains include/smb2/ and lib/
# ---------------------------------------------------------------------------
set(LP_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

if(NOT LP_FFMPEG_ROOT)
    if(DEFINED ANDROID_ABI)
        set(LP_FFMPEG_ROOT ${LP_ROOT}/third_party/ffmpeg/${ANDROID_ABI})
    elseif(APPLE)
        set(LP_FFMPEG_ROOT ${LP_ROOT}/third_party/ffmpeg/apple)
    endif()
endif()

message(STATUS "lanplayer: FFmpeg root = ${LP_FFMPEG_ROOT}")
message(STATUS "lanplayer: libsmb2 root = ${LP_SMB2_ROOT}")

# ---------------------------------------------------------------------------
# Core sources (platform independent)
# ---------------------------------------------------------------------------
set(LP_CORE_SOURCES
    src/util/lp_str.c
    src/util/lp_log.c
    src/core/queue.c
    src/core/audio_ring.c
    src/core/demux.c
    src/core/video.c
    src/core/audio.c
    src/core/subtitle.c
    src/core/player.c
    src/source/url.c
    src/source/io.c
    src/source/smb.c
    src/source/file.c
)

if(ANDROID)
    set(LP_PLATFORM_SOURCES
        src/platform/android/media_codec_decoder.c
        src/platform/android/egl_renderer.c
        src/platform/android/aaudio_sink.c
        src/platform/android/jni_bridge.c
    )
elseif(APPLE)
    set(LP_PLATFORM_SOURCES
        src/platform/apple/videotoolbox_decoder.c
        src/platform/apple/coreaudio_sink.c
        src/platform/apple/apple_texture.c
    )
else()
    set(LP_PLATFORM_SOURCES
        src/platform/stub/stub_platform.c
    )
endif()

# Apple 上必须是 STATIC：Dart 侧对 iOS / macOS 用的是 DynamicLibrary.process()
# （见 app/lib/core/bindings.dart），内核必须链进 app 二进制，不能是 .dylib。
# 其余平台仍是 SHARED（Android 的 liblanplayer.so、Windows 的 lanplayer.dll，
# 以及 Linux/CI 用的 .so）。
if(APPLE)
    add_library(lanplayer STATIC ${LP_CORE_SOURCES} ${LP_PLATFORM_SOURCES})
else()
    add_library(lanplayer SHARED ${LP_CORE_SOURCES} ${LP_PLATFORM_SOURCES})
endif()

target_include_directories(lanplayer PUBLIC
    ${LP_ROOT}/include
    ${LP_ROOT}/src
    ${LP_ROOT}/src/source
)

# ---------------------------------------------------------------------------
# FFmpeg
# ---------------------------------------------------------------------------
if(EXISTS ${LP_FFMPEG_ROOT}/include/libavformat/avformat.h)
    target_include_directories(lanplayer PRIVATE ${LP_FFMPEG_ROOT}/include)
    if(ANDROID)
        set(_abi ${ANDROID_ABI})
        foreach(_lib avformat avcodec avutil swresample swscale avfilter)
            add_library(ff_${_lib} SHARED IMPORTED)
            set_target_properties(ff_${_lib} PROPERTIES
                IMPORTED_LOCATION ${LP_FFMPEG_ROOT}/lib/${_abi}/lib${_lib}.so)
        endforeach()
    else()
        foreach(_lib avformat avcodec avutil swresample swscale avfilter)
            add_library(ff_${_lib} STATIC IMPORTED)
            set_target_properties(ff_${_lib} PROPERTIES
                IMPORTED_LOCATION ${LP_FFMPEG_ROOT}/lib/lib${_lib}.a)
        endforeach()
    endif()
    set(LP_FF_LIBS ff_avformat ff_avcodec ff_swresample ff_avfilter ff_swscale ff_avutil)
endif()

# ---------------------------------------------------------------------------
# libsmb2 (SMB2/3 client)
# ---------------------------------------------------------------------------
if(LP_SMB2_ROOT AND EXISTS ${LP_SMB2_ROOT}/include/smb2/libsmb2.h)
    target_include_directories(lanplayer PRIVATE ${LP_SMB2_ROOT}/include)
    if(ANDROID)
        add_library(smb2 SHARED IMPORTED)
        set_target_properties(smb2 PROPERTIES
            IMPORTED_LOCATION ${LP_SMB2_ROOT}/lib/${ANDROID_ABI}/libsmb2.so)
    else()
        add_library(smb2 STATIC IMPORTED)
        set_target_properties(smb2 PROPERTIES IMPORTED_LOCATION ${LP_SMB2_ROOT}/lib/libsmb2.a)
    endif()
    target_link_libraries(lanplayer PRIVATE smb2)
    target_compile_definitions(lanplayer PRIVATE LP_HAVE_SMB2=1)
else()
    message(WARNING "libsmb2 not found: SMB support will fail at runtime")
endif()

# ---------------------------------------------------------------------------
# Platform libraries
# ---------------------------------------------------------------------------
if(ANDROID)
    target_link_libraries(lanplayer PUBLIC
        ${LP_FF_LIBS}
        android
        log
        mediandk
        EGL
        GLESv2
        aaudio
    )
    target_compile_definitions(lanplayer PRIVATE LP_PLATFORM_ANDROID=1)
elseif(APPLE)
    find_library(FW_VIDEOTOOLBOX VideoToolbox)
    find_library(FW_COREMEDIA CoreMedia)
    find_library(FW_COREVIDEO CoreVideo)
    find_library(FW_AUDIOTOOLBOX AudioToolbox)
    find_library(FW_COREFOUNDATION CoreFoundation)
    find_library(FW_COREVIDEO_TOOLBOX CoreVideoToolbox OPTIONAL)
    target_link_libraries(lanplayer PUBLIC
        ${LP_FF_LIBS}
        ${FW_VIDEOTOOLBOX} ${FW_COREMEDIA} ${FW_COREVIDEO}
        ${FW_AUDIOTOOLBOX} ${FW_COREFOUNDATION}
        iconv
    )
    target_compile_definitions(lanplayer PRIVATE LP_PLATFORM_APPLE=1 LP_HAVE_ICONV=1)
    # VideoToolbox output handlers are blocks.
    target_compile_options(lanplayer PRIVATE -fblocks)
else()
    target_link_libraries(lanplayer PUBLIC ${LP_FF_LIBS})
    find_package(Iconv QUIET)
    if(Iconv_FOUND)
        target_link_libraries(lanplayer PRIVATE Iconv::Iconv)
        target_compile_definitions(lanplayer PRIVATE LP_HAVE_ICONV=1)
    endif()
endif()

if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(lanplayer PUBLIC pthread m)
endif()

target_compile_definitions(lanplayer PRIVATE
    LP_ENABLE_HTTP=1
    _FILE_OFFSET_BITS=64
    _GNU_SOURCE
)

set_target_properties(lanplayer PROPERTIES
    OUTPUT_NAME lanplayer
    C_VISIBILITY_PRESET hidden
)

# Export only the lp_* symbols from the shared object.
if(APPLE)
    # Apple 上是静态库，没有链接阶段，导出表由最终 app 决定。
    # 但 visibility 必须放开成 default：Dart 侧用 DynamicLibrary.process()
    # （等价于 dlsym(RTLD_DEFAULT)），hidden 符号在那里查不到，app 会报
    # "symbol not found: lp_player_create"。
    set_target_properties(lanplayer PROPERTIES
        C_VISIBILITY_PRESET default
        XCODE_ATTRIBUTE_GCC_SYMBOLS_PRIVATE_EXTERN NO)
elseif(ANDROID)
    target_link_options(lanplayer PRIVATE
        "-Wl,--version-script=${LP_ROOT}/lp_map.txt")
endif()

if(NOT DEFINED LP_NO_TESTS)
    add_executable(lp_smoke_test tests/lp_smoke_test.c)
    target_link_libraries(lp_smoke_test PRIVATE lanplayer)
endif()
