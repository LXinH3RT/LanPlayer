// Raw dart:ffi bindings for the LanPlayer native core.
//
// Everything crosses the boundary as JSON strings or scalars, so the ABI is
// stable across FFmpeg/NDK versions: see native/include/lanplayer/lp_player.h.
import 'dart:ffi';
import 'dart:io';

import 'dart:convert';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int abiVersion = 1;

/// 一帧缩略图：[rgba] 是每像素 4 字节的 RGBA8888，行间无 padding。
class ThumbnailResult {
  const ThumbnailResult(
      {required this.width, required this.height, required this.rgba});

  final int width;
  final int height;
  final Uint8List rgba;
}

typedef _ResultInt32C = Int32 Function();
typedef _ResultInt32D = int Function();

typedef _CreateC = Int32 Function(Pointer<Pointer<Void>> out);
typedef _CreateD = int Function(Pointer<Pointer<Void>> out);

typedef _HandleC = Void Function(Pointer<Void> player);
typedef _HandleD = void Function(Pointer<Void> player);

typedef _HandleInt32C = Int32 Function(Pointer<Void> player);
typedef _HandleInt32D = int Function(Pointer<Void> player);

typedef _HandleInt64C = Int32 Function(Pointer<Void> player, Int64 value);
typedef _HandleInt64D = int Function(Pointer<Void> player, int value);

typedef _HandleFloatC = Int32 Function(Pointer<Void> player, Float value);
typedef _HandleFloatD = int Function(Pointer<Void> player, double value);

typedef _OpenC = Int32 Function(
    Pointer<Void> player, Pointer<Utf8> url, Pointer<Utf8> options);
typedef _OpenD = int Function(
    Pointer<Void> player, Pointer<Utf8> url, Pointer<Utf8> options);

typedef LpEventCbC = Void Function(
    Pointer<Void> user, Int32 event, Pointer<Utf8> json, Int64 value);

typedef LpSetEventCbC = Void Function(Pointer<Void> player,
    Pointer<NativeFunction<LpEventCbC>> cb, Pointer<Void> user);
typedef LpSetEventCbD = void Function(Pointer<Void> player,
    Pointer<NativeFunction<LpEventCbC>> cb, Pointer<Void> user);

/* player + one int32 (set_mute, set_scale_mode, select_track's first arg, ...) */
typedef _Int32ArgC = Int32 Function(Pointer<Void> player, Int32 value);
typedef _Int32ArgD = int Function(Pointer<Void> player, int value);

typedef _TrackC = Int32 Function(Pointer<Void> player, Int32 type, Int32 index);
typedef _TrackD = int Function(Pointer<Void> player, int type, int index);

typedef _GetInt64C = Int32 Function(Pointer<Void> player, Pointer<Int64> out);
typedef _GetInt64D = int Function(Pointer<Void> player, Pointer<Int64> out);

typedef _GetStringC = Int32 Function(
    Pointer<Void> player, Pointer<Pointer<Utf8>> out);
typedef _GetStringD = int Function(
    Pointer<Void> player, Pointer<Pointer<Utf8>> out);

typedef _SurfaceC = Int32 Function(
    Pointer<Void> player, Pointer<Void> window, Int32 w, Int32 h);
typedef _SurfaceD = int Function(
    Pointer<Void> player, Pointer<Void> window, int w, int h);

typedef _SurfaceSizeC = Int32 Function(Pointer<Void> player, Int32 w, Int32 h);
typedef _SurfaceSizeD = int Function(Pointer<Void> player, int w, int h);

typedef LpFrameCbC = Void Function(Pointer<Void> user);

typedef LpInstallFrameCbC = Int32 Function(Pointer<Void> player,
    Pointer<NativeFunction<LpFrameCbC>> cb, Pointer<Void> user);
typedef LpInstallFrameCbD = int Function(Pointer<Void> player,
    Pointer<NativeFunction<LpFrameCbC>> cb, Pointer<Void> user);

typedef _OptionC = Int32 Function(
    Pointer<Void> player, Pointer<Utf8> key, Pointer<Utf8> value);
typedef _OptionD = int Function(
    Pointer<Void> player, Pointer<Utf8> key, Pointer<Utf8> value);

typedef _AddSubC = Int32 Function(
    Pointer<Void> player, Pointer<Utf8> url, Pointer<Utf8> options);
typedef _AddSubD = int Function(
    Pointer<Void> player, Pointer<Utf8> url, Pointer<Utf8> options);

typedef _SourceListC = Int32 Function(
    Pointer<Utf8> url, Pointer<Utf8> options, Pointer<Pointer<Utf8>> out);
typedef _SourceListD = int Function(
    Pointer<Utf8> url, Pointer<Utf8> options, Pointer<Pointer<Utf8>> out);

typedef _SourceErrC = Int32 Function(Pointer<Pointer<Utf8>> out);
typedef _SourceErrD = int Function(Pointer<Pointer<Utf8>> out);

typedef _ThumbC = Int32 Function(
    Pointer<Utf8> url,
    Pointer<Utf8> options,
    Int32 maxWidth,
    Pointer<Pointer<Void>> outPixels,
    Pointer<Int32> outWidth,
    Pointer<Int32> outHeight);
typedef _ThumbD = int Function(
    Pointer<Utf8> url,
    Pointer<Utf8> options,
    int maxWidth,
    Pointer<Pointer<Void>> outPixels,
    Pointer<Int32> outWidth,
    Pointer<Int32> outHeight);

typedef _FreeBufferC = Void Function(Pointer<Void> buf);
typedef _FreeBufferD = void Function(Pointer<Void> buf);

typedef _FreeC = Void Function(Pointer<Utf8> s);
typedef _FreeD = void Function(Pointer<Utf8> s);

/// Thin, allocation-safe wrapper over the shared library.
class NativeCore {
  NativeCore._(this._lib);

  final DynamicLibrary _lib;

  static NativeCore? _instance;
  static NativeCore get instance => _instance ??= NativeCore._(_open());

  static DynamicLibrary _open() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('liblanplayer.so');
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isMacOS) {
      // Xcode links the static core into the app binary.
      return DynamicLibrary.process();
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('lanplayer.dll');
    }
    return DynamicLibrary.open('liblanplayer.so');
  }

  late final _ResultInt32D _abi =
      _lib.lookupFunction<_ResultInt32C, _ResultInt32D>('lp_abi_version');
  late final _CreateD _create =
      _lib.lookupFunction<_CreateC, _CreateD>('lp_player_create');
  late final _HandleD _destroy =
      _lib.lookupFunction<_HandleC, _HandleD>('lp_player_destroy');
  late final LpSetEventCbD _setEventCb =
      _lib.lookupFunction<LpSetEventCbC, LpSetEventCbD>(
          'lp_player_set_event_callback');
  late final _OpenD _openMedia =
      _lib.lookupFunction<_OpenC, _OpenD>('lp_player_open');
  late final _HandleInt32D _close =
      _lib.lookupFunction<_HandleInt32C, _HandleInt32D>('lp_player_close');
  late final _HandleInt32D _play =
      _lib.lookupFunction<_HandleInt32C, _HandleInt32D>('lp_player_play');
  late final _HandleInt32D _pause =
      _lib.lookupFunction<_HandleInt32C, _HandleInt32D>('lp_player_pause');
  late final _HandleInt32D _stop =
      _lib.lookupFunction<_HandleInt32C, _HandleInt32D>('lp_player_stop');
  late final _HandleInt64D _seek =
      _lib.lookupFunction<_HandleInt64C, _HandleInt64D>('lp_player_seek');
  late final _HandleFloatD _setSpeed =
      _lib.lookupFunction<_HandleFloatC, _HandleFloatD>('lp_player_set_speed');
  late final _HandleFloatD _setVolume =
      _lib.lookupFunction<_HandleFloatC, _HandleFloatD>('lp_player_set_volume');
  late final _Int32ArgD _setMute =
      _lib.lookupFunction<_Int32ArgC, _Int32ArgD>('lp_player_set_mute');
  late final _TrackD _selectTrack =
      _lib.lookupFunction<_TrackC, _TrackD>('lp_player_select_track');
  late final _AddSubD _addSubtitle =
      _lib.lookupFunction<_AddSubC, _AddSubD>('lp_player_add_subtitle');
  late final _HandleInt64D _setSubtitleDelay =
      _lib.lookupFunction<_HandleInt64C, _HandleInt64D>(
          'lp_player_set_subtitle_delay');
  late final _HandleInt32D _getState =
      _lib.lookupFunction<_HandleInt32C, _HandleInt32D>('lp_player_get_state');
  late final _GetInt64D _getPosition =
      _lib.lookupFunction<_GetInt64C, _GetInt64D>('lp_player_get_position');
  late final _GetInt64D _getDuration =
      _lib.lookupFunction<_GetInt64C, _GetInt64D>('lp_player_get_duration');
  late final _GetStringD _getMediaInfo =
      _lib.lookupFunction<_GetStringC, _GetStringD>('lp_player_get_media_info');
  late final _SurfaceD _setSurface =
      _lib.lookupFunction<_SurfaceC, _SurfaceD>('lp_player_set_surface');
  late final _SurfaceSizeD _setSurfaceSize =
      _lib.lookupFunction<_SurfaceSizeC, _SurfaceSizeD>(
          'lp_player_set_surface_size');
  late final _Int32ArgD _setScaleMode =
      _lib.lookupFunction<_Int32ArgC, _Int32ArgD>('lp_player_set_scale_mode');
  late final LpInstallFrameCbD _installFrameCb =
      _lib.lookupFunction<LpInstallFrameCbC, LpInstallFrameCbD>(
          'lp_player_install_frame_callback');
  late final _OptionD _setOption =
      _lib.lookupFunction<_OptionC, _OptionD>('lp_player_set_option');
  late final _SourceListD _sourceList =
      _lib.lookupFunction<_SourceListC, _SourceListD>('lp_source_list');
  late final _SourceListD _sourceProbe =
      _lib.lookupFunction<_SourceListC, _SourceListD>('lp_source_probe');
  late final _FreeD _freeString =
      _lib.lookupFunction<_FreeC, _FreeD>('lp_string_free');
  late final _ThumbD _thumbnail =
      _lib.lookupFunction<_ThumbC, _ThumbD>('lp_source_thumbnail');
  late final _FreeBufferD _freeBuffer =
      _lib.lookupFunction<_FreeBufferC, _FreeBufferD>('lp_pixels_free');
  late final _SourceErrD _lastError =
      _lib.lookupFunction<_SourceErrC, _SourceErrD>('lp_source_last_error');

  /// Last transport error on this thread, or null when there is none.
  String? lastSourceError() {
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_lastError(out) != 0 || out.value == nullptr) {
        return null;
      }
      final json = out.value.toDartString();
      _freeString(out.value);
      final map = decodeJson(json);
      final msg = map?['message'] as String?;
      return (msg == null || msg.isEmpty) ? null : msg;
    } finally {
      calloc.free(out);
    }
  }

  int get version => _abi();

  /// Releases a string allocated by the core (event payloads, listings).
  void freeNativeString(Pointer<Utf8> s) {
    if (s.address != 0) {
      _freeString(s);
    }
  }

  Pointer<Void> createPlayer() {
    final out = calloc<Pointer<Void>>();
    try {
      final rc = _create(out);
      if (rc != 0 || out.value == nullptr) {
        throw StateError('lp_player_create failed: $rc');
      }
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void destroyPlayer(Pointer<Void> p) => _destroy(p);

  void setEventCallback(Pointer<Void> p, Pointer<NativeFunction<LpEventCbC>> cb,
          Pointer<Void> user) =>
      _setEventCb(p, cb, user);

  int open(Pointer<Void> p, String url, Map<String, dynamic> options) {
    final u = url.toNativeUtf8();
    final o = options.isEmpty ? nullptr.cast<Utf8>() : _jsonToNative(options);
    try {
      return _openMedia(p, u, o);
    } finally {
      calloc.free(u);
      if (o != nullptr) {
        calloc.free(o);
      }
    }
  }

  int close(Pointer<Void> p) => _close(p);
  int play(Pointer<Void> p) => _play(p);
  int pause(Pointer<Void> p) => _pause(p);
  int stop(Pointer<Void> p) => _stop(p);
  int seek(Pointer<Void> p, int micros) => _seek(p, micros);
  int setSpeed(Pointer<Void> p, double speed) => _setSpeed(p, speed);
  int setVolume(Pointer<Void> p, double volume) => _setVolume(p, volume);
  int setMute(Pointer<Void> p, bool muted) => _setMute(p, muted ? 1 : 0);
  int selectTrack(Pointer<Void> p, int type, int index) =>
      _selectTrack(p, type, index);
  int addSubtitle(Pointer<Void> p, String url, Map<String, dynamic> options) {
    final u = url.toNativeUtf8();
    final o = _jsonToNative(options);
    try {
      return _addSubtitle(p, u, o);
    } finally {
      calloc.free(u);
      calloc.free(o);
    }
  }

  int setSubtitleDelay(Pointer<Void> p, int delayMs) =>
      _setSubtitleDelay(p, delayMs);

  int getState(Pointer<Void> p) => _getState(p);

  int getPosition(Pointer<Void> p) {
    final out = calloc<Int64>();
    try {
      _getPosition(p, out);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  int getDuration(Pointer<Void> p) {
    final out = calloc<Int64>();
    try {
      _getDuration(p, out);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  Map<String, dynamic>? mediaInfo(Pointer<Void> p) {
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_getMediaInfo(p, out) != 0 || out.value == nullptr) {
        return null;
      }
      final json = out.value.toDartString();
      _freeString(out.value);
      return _decode(json);
    } finally {
      calloc.free(out);
    }
  }

  int setSurface(Pointer<Void> p, int windowPtr, int width, int height) =>
      _setSurface(p, Pointer<Void>.fromAddress(windowPtr), width, height);

  int setSurfaceSize(Pointer<Void> p, int width, int height) =>
      _setSurfaceSize(p, width, height);
  int setScaleMode(Pointer<Void> p, int mode) => _setScaleMode(p, mode);

  void installFrameCallback(Pointer<Void> p,
          Pointer<NativeFunction<LpFrameCbC>> cb, Pointer<Void> user) =>
      _installFrameCb(p, cb, user);

  int setOption(Pointer<Void> p, String key, String value) {
    final k = key.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      return _setOption(p, k, v);
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }

  Map<String, dynamic>? listDirectory(
      String url, Map<String, dynamic> options) {
    final u = url.toNativeUtf8();
    final o = _jsonToNative(options);
    final out = calloc<Pointer<Utf8>>();
    try {
      final rc = _sourceList(u, o, out);
      if (rc != 0 || out.value == nullptr) {
        return null;
      }
      final json = out.value.toDartString();
      _freeString(out.value);
      return _decode(json);
    } finally {
      calloc.free(u);
      calloc.free(o);
      calloc.free(out);
    }
  }

  Map<String, dynamic>? probeServer(String url, Map<String, dynamic> options) {
    final u = url.toNativeUtf8();
    final o = _jsonToNative(options);
    final out = calloc<Pointer<Utf8>>();
    try {
      final rc = _sourceProbe(u, o, out);
      if (rc != 0 || out.value == nullptr) {
        return null;
      }
      final json = out.value.toDartString();
      _freeString(out.value);
      return _decode(json);
    } finally {
      calloc.free(u);
      calloc.free(o);
      calloc.free(out);
    }
  }

  /// 取一帧缩略图（RGBA8888）。失败返回 null，原因用 [lastSourceError] 取。
  ///
  /// 这是同步 FFI 调用，会真的解码一帧（SMB 上通常几百毫秒），
  /// 调用方必须放到后台 isolate 或至少不要放在 build 里。
  ThumbnailResult? thumbnail(
      String url, Map<String, dynamic> options, int maxWidth) {
    final u = url.toNativeUtf8();
    final o = _jsonToNative(options);
    final outPixels = calloc<Pointer<Void>>();
    final outWidth = calloc<Int32>();
    final outHeight = calloc<Int32>();
    try {
      final rc = _thumbnail(u, o, maxWidth, outPixels, outWidth, outHeight);
      if (rc != 0 || outPixels.value == nullptr) {
        return null;
      }
      final w = outWidth.value;
      final h = outHeight.value;
      if (w <= 0 || h <= 0) {
        _freeBuffer(outPixels.value);
        return null;
      }
      final bytes =
          Uint8List.fromList(outPixels.value.cast<Uint8>().asTypedList(w * h * 4));
      _freeBuffer(outPixels.value);
      return ThumbnailResult(width: w, height: h, rgba: bytes);
    } finally {
      calloc.free(u);
      calloc.free(o);
      calloc.free(outPixels);
      calloc.free(outWidth);
      calloc.free(outHeight);
    }
  }

  Pointer<Utf8> _jsonToNative(Map<String, dynamic> options) {
    final json = jsonEncode(options);
    return json.toNativeUtf8();
  }

  Map<String, dynamic>? _decode(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

Map<String, dynamic>? decodeJson(String s) {
  final v = jsonDecode(s);
  return v is Map<String, dynamic> ? v : null;
}

String encodeJson(Map<String, dynamic> m) => jsonEncode(m);
