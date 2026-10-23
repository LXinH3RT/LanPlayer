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
        # scripts/build_android_deps.sh writes <out>/ffmpeg/android/<abi>/{include,lib/<abi>}
        set(LP_FFMPEG_ROOT ${LP_ROOT}/third_party/ffmpeg/android/${ANDROID_ABI})
    elseif(APPLE)
        set(LP_FFMPEG_ROOT ${LP_ROOT}/third_party/ffmpeg/apple)
    endif()
endif()

if(NOT LP_SMB2_ROOT AND DEFINED ANDROID_ABI)
    # scripts/build_android_deps.sh writes <out>/libsmb2/android/{include,lib/<abi>}
    set(LP_SMB2_ROOT ${LP_ROOT}/third_party/libsmb2/android)
endif()

# The Android Gradle project points both roots at the shared parent directory
# (third_party/ffmpeg, third_party/libsmb2) instead of the per-ABI prefix the
# build script writes.  Descend one level when that is what we were given, so a
# single -D flag works for every ABI.
if(DEFINED ANDROID_ABI)
    if(EXISTS ${LP_FFMPEG_ROOT}/android/${ANDROID_ABI}/include/libavformat/avformat.h)
        set(LP_FFMPEG_ROOT ${LP_FFMPEG_ROOT}/android/${ANDROID_ABI})
    endif()
    if(EXISTS ${LP_SMB2_ROOT}/android/lib/${ANDROID_ABI}/libsmb2.so)
        set(LP_SMB2_ROOT ${LP_SMB2_ROOT}/android)
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
    src/core/thumb.c
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
        # Desktop (Linux / macOS / Windows).  The prebuilts can be static or
        # shared depending on how FFmpeg was configured:
        #   * docs/build.md and the Apple scripts produce libav*.a;
        #   * the Linux CI job builds FFmpeg with --enable-shared, which only
        #     yields libav*.so, so a hard-coded .a import would make configure
        #     fail with "Cannot specify link libraries for target ...".
        # Pick whichever the prefix actually contains, in that order.  A
        # Windows-style shared import additionally needs IMPORTED_IMPLIB -
        # without it MSVC generators stop at configure time with
        # "IMPORTED_IMPLIB not set for imported target".
        foreach(_lib avformat avcodec avutil swresample swscale avfilter)
            unset(_ff_loc)
            unset(_ff_implib)
            unset(_ff_kind)
            if(WIN32)
                set(_cands lib${_lib}.a ${_lib}.lib lib${_lib}.dll.a)
            else()
                set(_cands lib${_lib}.a lib${_lib}.dylib lib${_lib}.so)
            endif()
            foreach(_cand ${_cands})
                if(EXISTS ${LP_FFMPEG_ROOT}/lib/${_cand})
                    set(_ff_loc ${LP_FFMPEG_ROOT}/lib/${_cand})
                    if(_cand MATCHES "\\.a$" AND NOT _cand MATCHES "\\.dll\\.a$")
                        set(_ff_kind STATIC)
                    elseif(WIN32)
                        set(_ff_kind SHARED)
                        set(_ff_implib ${_ff_loc})
                    else()
                        set(_ff_kind SHARED)
                    endif()
                    break()
                endif()
            endforeach()
            if(NOT _ff_loc)
                message(FATAL_ERROR
                    "lanplayer: no ${_lib} import library under "
                    "${LP_FFMPEG_ROOT}/lib - build FFmpeg first (docs/build.md)")
            endif()
            add_library(ff_${_lib} ${_ff_kind} IMPORTED)
            if(_ff_implib)
                # The DLL itself lives in <prefix>/bin on Windows; pass it along
                # when present so it can be copied next to the executable.
                file(GLOB _ff_dll ${LP_FFMPEG_ROOT}/bin/${_lib}-*.dll
                                   ${LP_FFMPEG_ROOT}/bin/lib${_lib}.dll
                                   ${LP_FFMPEG_ROOT}/bin/${_lib}.dll)
                if(_ff_dll)
                    list(GET _ff_dll 0 _ff_dll0)
                    set_target_properties(ff_${_lib} PROPERTIES
                        IMPORTED_LOCATION ${_ff_dll0}
                        IMPORTED_IMPLIB ${_ff_implib})
                else()
                    set_target_properties(ff_${_lib} PROPERTIES
                        IMPORTED_LOCATION ${_ff_implib}
                        IMPORTED_IMPLIB ${_ff_implib})
                endif()
            else()
                set_target_properties(ff_${_lib} PROPERTIES IMPORTED_LOCATION ${_ff_loc})
            endif()
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
        # Desktop: same story as FFmpeg above - accept a shared or a static
        # libsmb2 depending on how it was configured, and give MSVC the import
        # library when the archive is a DLL import stub.
        unset(_smb_loc)
        unset(_smb_implib)
        unset(_smb_kind)
        if(WIN32)
            set(_smb_cands libsmb2.a smb2.lib libsmb2.dll.a)
        else()
            set(_smb_cands libsmb2.a libsmb2.dylib libsmb2.so)
        endif()
        foreach(_cand ${_smb_cands})
            if(EXISTS ${LP_SMB2_ROOT}/lib/${_cand})
                set(_smb_loc ${LP_SMB2_ROOT}/lib/${_cand})
                if(_cand MATCHES "\\.a$" AND NOT _cand MATCHES "\\.dll\\.a$")
                    set(_smb_kind STATIC)
                elseif(WIN32)
                    set(_smb_kind SHARED)
                    set(_smb_implib ${_smb_loc})
                else()
                    set(_smb_kind SHARED)
                endif()
                break()
            endif()
        endforeach()
        if(NOT _smb_loc)
            message(FATAL_ERROR
                "lanplayer: no libsmb2 import library under "
                "${LP_SMB2_ROOT}/lib - run scripts/build_*_deps.sh first")
        endif()
        add_library(smb2 ${_smb_kind} IMPORTED)
        if(_smb_implib)
            file(GLOB _smb_dll ${LP_SMB2_ROOT}/bin/libsmb2-*.dll
                               ${LP_SMB2_ROOT}/bin/libsmb2.dll)
            if(_smb_dll)
                list(GET _smb_dll 0 _smb_dll0)
                set_target_properties(smb2 PROPERTIES
                    IMPORTED_LOCATION ${_smb_dll0}
                    IMPORTED_IMPLIB ${_smb_implib})
            else()
                set_target_properties(smb2 PROPERTIES
                    IMPORTED_LOCATION ${_smb_implib}
                    IMPORTED_IMPLIB ${_smb_implib})
            endif()
        else()
            set_target_properties(smb2 PROPERTIES IMPORTED_LOCATION ${_smb_loc})
        endif()
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
    # Foundation is not used directly, but VideoToolbox's block-based decode
    # callback pulls in NSUndefinedKeyException at link time: without it the
    # macOS build of anything linking the static library fails with
    #   Undefined symbols for architecture arm64: "_NSUndefinedKeyException"
    # (the iOS app links it transitively, the CMake test executables do not).
    find_library(FW_FOUNDATION Foundation)
    find_library(FW_COREVIDEO_TOOLBOX CoreVideoToolbox OPTIONAL)
    target_link_libraries(lanplayer PUBLIC
        ${LP_FF_LIBS}
        ${FW_VIDEOTOOLBOX} ${FW_COREMEDIA} ${FW_COREVIDEO}
        ${FW_AUDIOTOOLBOX} ${FW_COREFOUNDATION} ${FW_FOUNDATION}
        iconv
    )
    target_compile_definitions(lanplayer PRIVATE LP_PLATFORM_APPLE=1 LP_HAVE_ICONV=1)
    # The Apple FFmpeg prebuilts are configured with every demuxer enabled, and
    # matroskadec reaches for the bzip2 and liblzma decoders to unpack Matroska
    # header compression.  podspec links them for the app; the CMake
    # executables have to name them here or linking stops with
    #   "_BZ2_bzDecompress", referenced from _matroska_decode_buffer
    target_link_libraries(lanplayer PUBLIC bz2 lzma z)
    # Same story for libavfilter: vf_coreimage.o is pulled in (Apple FFmpeg
    # enables --enable-coreimage) and it calls CoreGraphics / CoreImage /
    # AppKit directly, so those frameworks have to be named explicitly too.
    find_library(FW_COREGRAPHICS CoreGraphics)
    find_library(FW_COREIMAGE CoreImage)
    find_library(FW_APPKIT AppKit)
    target_link_libraries(lanplayer PUBLIC
        ${FW_COREGRAPHICS} ${FW_COREIMAGE} ${FW_APPKIT})
    # Two more that only surface once vf_coreimage.o and tls_securetransport.o
    # are pulled in: OpenGL for CGLGetCurrentContext, and Security for the
    # SSLCreateContext family the SecureTransport TLS backend uses.
    find_library(FW_OPENGL OpenGL)
    find_library(FW_SECURITY Security)
    find_library(FW_QUARTZCORE QuartzCore)
    target_link_libraries(lanplayer PUBLIC
        ${FW_OPENGL} ${FW_SECURITY} ${FW_QUARTZCORE})
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

# `if(NOT LP_NO_TESTS)` rather than `if(NOT DEFINED LP_NO_TESTS)`: the CI job
# passes -DLP_NO_TESTS=OFF to ask for the smoke test, and `DEFINED` would treat
# that exactly like ON (defined is defined), so the executable was never built
# and `./build/lp_smoke_test` failed with "No such file or directory".
if(NOT LP_NO_TESTS)
    add_executable(lp_smoke_test tests/lp_smoke_test.c)
    target_link_libraries(lp_smoke_test PRIVATE lanplayer)
endif()
