import 'dart:io';

import 'package:flutter/services.dart';

/// Android 的媒体读取权限结果。
///
/// Android 14 起有第三种状态「选择部分」：只授予用户勾中的几张图/几个视频，
/// 目录里其它文件一律读不到。对文件浏览来说这等于「只看到一半」，所以要和
/// 「完全没给」区分开，好给用户一句准确的提示。
class MediaPermissionResult {
  const MediaPermissionResult({required this.granted, required this.partial});

  static const denied = MediaPermissionResult(granted: false, partial: false);
  static const full = MediaPermissionResult(granted: true, partial: false);

  final bool granted;

  /// 只有部分媒体被授权（Android 14 的「选择部分」）。
  final bool partial;

  static MediaPermissionResult fromMap(Map<String, dynamic>? map) =>
      MediaPermissionResult(
        granted: map?['granted'] == true,
        partial: map?['partial'] == true,
      );
}

/// Android 的媒体读取权限。
///
/// 清单里声明 READ_MEDIA_VIDEO 只是「有资格申请」，真正拿权限要运行时弹窗。
/// 少了这一步，新装的机器点「播放本地视频」会看到空目录 —— 看起来像浏览
/// 功能的 bug，其实是权限没给。iOS 由系统在访问相册时自己弹，桌面不需要。
class MediaPermission {
  static const MethodChannel _channel = MethodChannel('lanplayer/permissions');

  /// 只在 Android 上需要；其它平台一律当作已授权。
  static bool get isNeeded => Platform.isAndroid;

  /// 查询当前状态，不弹窗。
  static Future<MediaPermissionResult> status() async {
    if (!isNeeded) return MediaPermissionResult.full;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('status');
      return MediaPermissionResult.fromMap(res);
    } on PlatformException catch (_) {
      return MediaPermissionResult.denied;
    } on MissingPluginException catch (_) {
      // 平台通道不在（测试宿主、桌面）时不要卡住流程。
      return MediaPermissionResult.full;
    }
  }

  /// 申请权限。已经授权过就直接返回，不弹窗。
  static Future<MediaPermissionResult> request() async {
    if (!isNeeded) return MediaPermissionResult.full;
    try {
      final res =
          await _channel.invokeMapMethod<String, dynamic>('requestMedia');
      return MediaPermissionResult.fromMap(res);
    } on PlatformException catch (_) {
      return MediaPermissionResult.denied;
    } on MissingPluginException catch (_) {
      return MediaPermissionResult.full;
    }
  }
}
