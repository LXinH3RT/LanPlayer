import 'dart:io';

import '../core/background.dart';
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

/// 一次目录列表请求：返回内核的原始 JSON，失败返回 null。
///
/// 抽成函数类型是为了让测试能换成不碰 SMB 的假实现 —— 真实现要起后台
/// isolate 并加载动态库，widget 测试里跑不起来。
typedef ListingFetcher = Future<String?> Function(
    String url, Map<String, dynamic> options);

/// UI 访问共享所需的全部能力：目录浏览、凭据校验，以及两个入口
/// （已保存的配置、单个共享地址）。
///
/// **所有会触网的方法都不在主 isolate 上跑。** `lp_source_list` 是同步 C
/// 函数，服务器不应答时要等到 socket 超时（默认 15 s），在主 isolate 上调用
/// 会把整个界面冻住：窗口一片白、按钮点了没水波纹、转圈不动。所以这些入口
/// 统一走 [listDirectoryInBackground] / [probeServerInBackground]。
class MediaRepository {
  MediaRepository({ListingFetcher? fetchListing})
      : _fetch = fetchListing ?? listDirectoryInBackground;

  /// 真正去取列表的实现。默认走后台 isolate；测试可以换成假的。
  final ListingFetcher _fetch;

  /// 给测试用的只读入口：确认仓库默认把请求交给了后台 isolate。
  ListingFetcher get fetchListingForTest => _fetch;

  Future<DirectoryListing> browse(ServerProfile profile, {String? url}) async {
    final target = url ?? profile.rootUrl;
    final listing = await _fetch(target, profile.transportOptions());
    if (listing == null) {
      throw MediaSourceException(_errorFor(target));
    }
    return DirectoryListing.fromJson(decodeJson(listing) ?? const {});
  }

  Future<DirectoryListing> browseUrl(
      String url, Map<String, dynamic> options) async {
    final listing = await _fetch(url, options);
    if (listing == null) {
      throw MediaSourceException(_errorFor(url));
    }
    return DirectoryListing.fromJson(decodeJson(listing) ?? const {});
  }

  /// 失败时给用户的文案。
  ///
  /// 后台 isolate 里内核记的错误是线程本地的，跨 isolate 拿不到，所以这里只
  /// 给一条通用说法。以前能显示内核原文（`connect //host/share failed:
  /// Timeout expired and no connection exists`），代价是整个界面在请求期间
  /// 冻住十几秒 —— 那条细节不值得。
  String _errorFor(String url) => '无法访问 $url：连接超时或服务器不可达';

  /// Verifies credentials without listing a directory.
  Future<void> probe(ServerProfile profile) async {
    await probeServer(profile);
  }

  /// 只校验账号密码：真的连一次服务器，连上了就返回，不列共享。
  Future<SourceProbe> probeServer(ServerProfile profile) async {
    final raw = await probeServerInBackground(
      'smb://${profile.host}${profile.port == 445 ? '' : ':${profile.port}'}/${profile.share}',
      profile.transportOptions(),
    );
    if (raw == null) {
      throw MediaSourceException('认证失败：连不上 ${profile.host}');
    }
    return SourceProbe.fromJson(decodeJson(raw) ?? const {});
  }

  /// 单个文件作为来源时用的「列表」：父目录里只留下这个文件本身，外加与它
  /// 同名的外挂字幕。
  ///
  /// 首页每一块来源都按「一行行的目录内容」渲染，而一行要靠整份
  /// [DirectoryListing] 才能认出外挂字幕（[DirectoryListing.subtitlesFor]
  /// 是拿同一份 entries 比名字的）。所以这里把父目录完整列一遍再裁出需要的
  /// 那几项，比在界面层拼一个假列表更可靠。
  Future<DirectoryListing> browseFile(String path) async {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    final parent = cut > 0 ? path.substring(0, cut) : path;
    final name = cut >= 0 ? path.substring(cut + 1) : path;
    final dir = await browseUrl('file://$parent', const {'list_all': 1});
    final own = dir.entries.where((e) => !e.isDir && e.name == name).toList();
    if (own.isEmpty) {
      throw MediaSourceException('这个文件已经不在了：$path');
    }
    final probe = DirectoryListing(
      url: dir.url,
      parent: dir.parent,
      entries: [own.first, ...dir.entries.where((e) => e.isSubtitle)],
    );
    return DirectoryListing(
      url: dir.url,
      parent: dir.parent,
      entries: [own.first, ...probe.subtitlesFor(own.first)],
    );
  }

  /// Entry point for module 5: local storage.
  Future<DirectoryListing> browseLocal(String path) async {
    final listing = await _fetch('file://$path', const {});
    if (listing == null) {
      throw MediaSourceException('无法读取 $path');
    }
    return DirectoryListing.fromJson(decodeJson(listing) ?? const {});
  }

  /// Well known local roots; the Android/iOS sandboxes expose different paths.
  ///
  /// 桌面端在常用位置前面再补上所有盘符：只给「主目录」和「下载」的话，
  /// 片子放在别的盘就点不到了。
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
      roots.addAll(_windowsDrives());
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '/';
      roots.add((label: '主目录', path: home));
      roots.add((label: '下载', path: '$home/Downloads'));
    }
    return roots;
  }

  /// Windows 上能访问的盘符，按字母序。其它系统返回空。
  ///
  /// 不查 GetLogicalDrives，直接试一遍 A–Z：能 `stat` 到就当它是可用的根。
  /// 光驱空着、网络盘掉线之类的情况自然就被跳过了。
  List<({String label, String path})> _windowsDrives() {
    if (!Platform.isWindows) return const [];
    final out = <({String label, String path})>[];
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final letter = String.fromCharCode(code);
      final path = '$letter:\\';
      try {
        if (Directory(path).existsSync()) {
          out.add((label: '$letter 盘', path: path));
        }
      } catch (_) {
        // 没插盘 / 没权限：跳过，别让一个坏盘符挡住整个列表。
      }
    }
    return out;
  }
}
