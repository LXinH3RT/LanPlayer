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

/// 一次目录列表请求：返回内核的原始 JSON，失败时带分类码。
///
/// 抽成函数类型是为了让测试能换成不碰 SMB 的假实现 —— 真实现要起后台
/// isolate 并加载动态库，widget 测试里跑不起来。
typedef ListingFetcher = Future<ListingResult> Function(
    String url, Map<String, dynamic> options);

/// 一次盘符探测：返回真实存在的根（形如 `C:\`）。
///
/// 与 [ListingFetcher] 同理抽成函数类型，测试里可以换成不碰磁盘的假实现 ——
/// 真实现要起后台 isolate，widget 测试里跑不起来。
typedef DriveScanner = Future<List<String>> Function();

/// UI 访问共享所需的全部能力：目录浏览、凭据校验，以及两个入口
/// （已保存的配置、单个共享地址）。
///
/// **所有会触网的方法都不在主 isolate 上跑。** `lp_source_list` 是同步 C
/// 函数，服务器不应答时要等到 socket 超时（默认 15 s），在主 isolate 上调用
/// 会把整个界面冻住：窗口一片白、按钮点了没水波纹、转圈不动。所以这些入口
/// 统一走 [listDirectoryInBackground] / [probeServerInBackground]。
class MediaRepository {
  MediaRepository({ListingFetcher? fetchListing, DriveScanner? scanDrives})
      : _fetch = fetchListing ?? listDirectoryInBackground,
        _scanDrives = scanDrives ?? windowsDriveRootsInBackground;

  /// 真正去取列表的实现。默认走后台 isolate；测试可以换成假的。
  final ListingFetcher _fetch;

  /// 盘符探测的实现。默认走后台 isolate；测试可以换成假的。
  final DriveScanner _scanDrives;

  /// 给测试用的只读入口：确认仓库默认把请求交给了后台 isolate。
  ListingFetcher get fetchListingForTest => _fetch;

  /// 给测试用的只读入口：确认盘符探测默认也交给了后台 isolate。
  DriveScanner get driveScannerForTest => _scanDrives;

  Future<DirectoryListing> browse(ServerProfile profile, {String? url}) async {
    final target = url ?? profile.rootUrl;
    final listing = await _fetch(target, profile.transportOptions());
    if (!listing.ok) {
      throw MediaSourceException(_errorFor(target, listing.failure));
    }
    return DirectoryListing.fromJson(decodeJson(listing.json!) ?? const {});
  }

  Future<DirectoryListing> browseUrl(
      String url, Map<String, dynamic> options) async {
    final listing = await _fetch(url, options);
    if (!listing.ok) {
      throw MediaSourceException(_errorFor(url, listing.failure));
    }
    return DirectoryListing.fromJson(decodeJson(listing.json!) ?? const {});
  }

  /// 失败时给用户的文案。
  ///
  /// 内核把失败分成几类（密码错、共享名或目录不存在、超时、连不上），这里
  /// 照分类给不同的话 —— 以前四种都是「连接超时或服务器不可达」，用户照着
  /// 那句话去查网线是白费力气，真正该改的是账号密码。
  String _errorFor(String url, SourceFailure? failure) {
    switch (failure?.code) {
      case SourceFailure.auth:
        return '无法访问 $url：账号或密码不对，或者没有这个共享';
      case SourceFailure.notFound:
        return '无法访问 $url：路径不存在';
      case SourceFailure.timeout:
        return '无法访问 $url：等待服务器响应超时';
      case SourceFailure.unsupported:
        return '无法访问 $url：这种地址不受支持';
      case SourceFailure.argument:
        return '无法访问 $url：地址格式不对';
      default:
        return '无法访问 $url：连接失败，服务器不可达或端口不通';
    }
  }

  /// Verifies credentials without listing a directory.
  Future<void> probe(ServerProfile profile) async {
    await probeServer(profile);
  }

  /// 只校验账号密码：真的连一次服务器，连上了就返回，不列共享。
  Future<SourceProbe> probeServer(ServerProfile profile) async {
    final result = await probeServerInBackground(
      'smb://${profile.host}${profile.port == 445 ? '' : ':${profile.port}'}/${profile.share}',
      profile.transportOptions(),
    );
    if (!result.ok) {
      final host = profile.host;
      final message = switch (result.failure?.code) {
        SourceFailure.auth => '认证失败：$host 上的账号或密码不对',
        SourceFailure.timeout => '认证失败：$host 没有响应（地址或端口不对，或被防火墙挡住）',
        _ => '认证失败：连不上 $host',
      };
      throw MediaSourceException(message);
    }
    return SourceProbe.fromJson(decodeJson(result.json!) ?? const {});
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
    if (!listing.ok) {
      final why =
          listing.failure?.code == SourceFailure.notFound ? '不存在' : '读不出来';
      throw MediaSourceException('$path 这个目录$why');
    }
    return DirectoryListing.fromJson(decodeJson(listing.json!) ?? const {});
  }

  /// Well known local roots; the Android/iOS sandboxes expose different paths.
  ///
  /// 桌面端在常用位置前面再补上所有盘符：只给「主目录」和「下载」的话，
  /// 片子放在别的盘就点不到了。
  ///
  /// **会同步 stat 盘符，所以是异步的，而且盘符探测在后台 isolate 上跑**
  /// （评审 4.8）：挂过掉线的网络盘时，`existsSync()` 在主 isolate 上要等
  /// 系统重试，添加本地文件夹的对话框会几秒不出现。其它平台不碰盘符。
  Future<List<({String label, String path})>> localRoots() async {
    final roots = <({String label, String path})>[];
    if (Platform.isAndroid) {
      roots.add((label: '内部存储', path: '/storage/emulated/0'));
      roots.add((label: '下载', path: '/storage/emulated/0/Download'));
      roots.add((label: '电影', path: '/storage/emulated/0/Movies'));
    } else if (Platform.isIOS) {
      final docs = Platform.environment['HOME'] ?? '';
      roots.add((label: 'App 文档', path: '$docs/Documents'));
    } else {
      for (final path in await _scanDrives()) {
        roots.add((label: '${path.substring(0, 1)} 盘', path: path));
      }
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '/';
      roots.add((label: '主目录', path: home));
      roots.add((label: '下载', path: '$home/Downloads'));
    }
    return roots;
  }
}
