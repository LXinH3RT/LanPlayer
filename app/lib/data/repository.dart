import 'dart:io';

import '../core/bindings.dart';
import 'models.dart';

class MediaSourceException implements Exception {
  MediaSourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 服务器对「凭据校验」的回答。
///
/// 只表示账号密码是否可用，不含共享列表 —— 客户端不枚举共享名，
/// 共享名由用户自己填写。
class SourceProbe {
  const SourceProbe({required this.server});

  factory SourceProbe.fromJson(Map<String, dynamic> json) =>
      SourceProbe(server: json['server'] as String? ?? '');

  /// 被校验的服务器地址（回显用）。
  final String server;
}

/// UI 访问共享所需的全部能力：目录浏览、凭据校验，以及两个入口
/// （已保存的配置、单个共享地址）。
class MediaRepository {
  MediaRepository({NativeCore? core}) : _core = core ?? NativeCore.instance;

  final NativeCore _core;

  Future<DirectoryListing> browse(ServerProfile profile, {String? url}) async {
    final target = url ?? profile.rootUrl;
    final json = _core.listDirectory(target, profile.transportOptions());
    if (json == null) {
      final detail = _core.lastSourceError();
      throw MediaSourceException(detail ?? '无法访问 $target');
    }
    return DirectoryListing.fromJson(json);
  }

  Future<DirectoryListing> browseUrl(
      String url, Map<String, dynamic> options) async {
    final json = _core.listDirectory(url, options);
    if (json == null) {
      throw MediaSourceException(_core.lastSourceError() ?? '无法访问 $url');
    }
    return DirectoryListing.fromJson(json);
  }

  /// Verifies credentials without listing a directory.
  Future<void> probe(ServerProfile profile) async {
    await probeServer(profile);
  }

  /// 只校验账号密码：真的连一次服务器，连上了就返回，不列共享。
  Future<SourceProbe> probeServer(ServerProfile profile) async {
    final json = _core.probeServer(
      'smb://${profile.host}${profile.port == 445 ? '' : ':${profile.port}'}/${profile.share}',
      profile.transportOptions(),
    );
    if (json == null) {
      throw MediaSourceException(_core.lastSourceError() ?? '认证失败');
    }
    return SourceProbe.fromJson(json);
  }

  /// Entry point for module 5: local storage.
  Future<DirectoryListing> browseLocal(String path) async {
    final json = _core.listDirectory('file://$path', const {});
    if (json == null) {
      throw MediaSourceException(_core.lastSourceError() ?? '无法读取 $path');
    }
    return DirectoryListing.fromJson(json);
  }

  /// Well known local roots; the Android/iOS sandboxes expose different paths.
  List<({String label, String path})> localRoots() {
    final roots = <({String label, String path})>[];
    if (Platform.isAndroid) {
      roots.add((label: '内部存储', path: '/storage/emulated/0'));
      roots.add((label: '下载', path: '/storage/emulated/0/Download'));
      roots.add((label: '电影', path: '/storage/emulated/0/Movies'));
    } else if (Platform.isIOS) {
      final docs = Platform.environment['HOME'] ?? '';
      roots.add((label: 'App 文档', path: '$docs/Documents'));
    } else {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '/';
      roots.add((label: '主目录', path: home));
      roots.add((label: '下载', path: '$home/Downloads'));
    }
    return roots;
  }
}
