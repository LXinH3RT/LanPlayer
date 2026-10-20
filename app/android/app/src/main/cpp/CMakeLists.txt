# Pulls the shared native core (native/) into the Android build.
#
# The FFmpeg and libsmb2 prebuilts live in native/third_party/, see
# docs/build.md for how to produce them (they are not checked in).
cmake_minimum_required(VERSION 3.22)

set(LP_NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../native)

if(NOT LP_FFMPEG_ROOT)
    set(LP_FFMPEG_ROOT ${LP_NATIVE_ROOT}/third_party/ffmpeg)
endif()
if(NOT LP_SMB2_ROOT)
    set(LP_SMB2_ROOT ${LP_NATIVE_ROOT}/third_party/libsmb2)
endif()

set(LP_NO_TESTS ON CACHE BOOL "" FORCE)

add_subdirectory(${LP_NATIVE_ROOT} lanplayer_build)
