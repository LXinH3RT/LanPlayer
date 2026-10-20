/// Windows texture bridge for the LanPlayer FFmpeg core.
///
/// The actual work happens in the native plugin (`windows/lanplayer_video_plugin.cpp`):
/// it loads `lanplayer.dll`, registers a Flutter texture and pushes decoded
/// frames into it.  The Dart side talks to it through the same
/// `lanplayer/video` method channel that the Android and iOS hosts implement,
/// so `PlaybackController` and the player UI are platform agnostic.
library;

/// Version of the bridge contract; bump together with the native side.
const String lanplayerVideoBridgeVersion = '1';
