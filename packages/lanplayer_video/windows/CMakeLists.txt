# Windows plugin build for the LanPlayer texture bridge.
#
# Follows the standard Flutter Windows plugin template: the generated
# `generated_plugins.cmake` adds this directory and links `lanplayer_video_plugin`.
cmake_minimum_required(VERSION 3.14)

set(PLUGIN_NAME "lanplayer_video_plugin")

add_library(${PLUGIN_NAME} SHARED
  "lanplayer_video_plugin.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN TRUE
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  user32     # window surface bridging
  version    # GetFileVersionInfoW / VerQueryValueW (CompanyName, ProductName)
  ole32      # CoTaskMemFree for SHGetKnownFolderPath
  shell32    # SHGetKnownFolderPath (fallback storage directory)
)
