/*
 * Windows plugin entry point for the LanPlayer video texture bridge.
 *
 * Registered automatically by Flutter's generated_plugin_registrant.cc when the
 * `lanplayer_video` path package is a dependency of the app.
 */
#ifndef FLUTTER_PLUGIN_LANPLAYER_VIDEO_PLUGIN_H_
#define FLUTTER_PLUGIN_LANPLAYER_VIDEO_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void LanPlayerVideoPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_LANPLAYER_VIDEO_PLUGIN_H_
