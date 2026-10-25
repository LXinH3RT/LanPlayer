import 'location.dart';
import 'models.dart';
import 'folders.dart';

/// 首页上的一块来源属于哪一类。
enum HomeSourceKind { server, folder }

/// 首页直接展开的一块来源：一台 SMB 服务器，或者一个加进来的本机文件夹。
///
/// 首页不再只列「卡片」，而是把每一块的根目录内容直接摊开；所以这里带上
/// 展开这块目录所需的全部信息（[location]），免得界面层再回头查两个存储。
class HomeSource {
  const HomeSource({
    required this.id,
    required this.kind,
    required this.label,
    required this.subtitle,
    required this.location,
    this.profile,
    this.folder,
  });

  /// 稳定标识：SMB 用 `srv:<id>`，本机文件夹用 `dir:<id>`。
  ///
  /// 两种来源的 id 各自独立生成，加前缀才能在同一个映射里区分开
  /// （同一个数字 id 不会互相覆盖）。
  final String id;
  final HomeSourceKind kind;
  final String label;

  /// 副标题：服务器写 `smb://host/share · 用户 x`，文件夹写路径。
  final String subtitle;
  final MediaLocation location;

  /// 来源对应的存储记录，用于编辑 / 删除。
  final ServerProfile? profile;
  final LocalFolder? folder;

  bool get isServer => kind == HomeSourceKind.server;
}

/// 把两类存储拼成首页要展示的来源顺序：先服务器，再本机文件夹，各组内
/// 保持存储里的原顺序（服务器按添加顺序，文件夹按加进首页的顺序）。
///
/// 不按 `lastUsedAt` 重排是刻意的：首页几块的位置一动，用户靠位置找东西的
/// 习惯就被打断，比「最近用过的排前面」更烦人。
List<HomeSource> buildHomeSources(
  List<ServerProfile> servers,
  List<LocalFolder> folders,
) {
  final out = <HomeSource>[];
  for (final s in servers) {
    out.add(HomeSource(
      id: 'srv:${s.id}',
      kind: HomeSourceKind.server,
      label: s.displayName,
      subtitle: describeServerLine(s),
      location: MediaLocation.fromProfile(s),
      profile: s,
    ));
  }
  for (final f in folders) {
    out.add(HomeSource(
      id: 'dir:${f.id}',
      kind: HomeSourceKind.folder,
      label: f.label.isEmpty ? _lastSegment(f.path) : f.label,
      subtitle: f.path,
      location: MediaLocation.local(f.label, f.path),
      folder: f,
    ));
  }
  return out;
}

/// 服务器那一行的副标题：根地址 + 认证方式。
///
/// 与 `ui/feedback.dart` 的 [describeServer] 同义，但放在数据层供纯函数测试
/// 使用（界面层的那个还带着 Widget 依赖）。
String describeServerLine(ServerProfile p) {
  final parts = <String>[p.rootUrl];
  if (p.user.isNotEmpty) parts.add('用户 ${p.user}');
  return parts.join('  ·  ');
}

String _lastSegment(String path) {
  final segments = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

/// 首页每一块要渲染的行。
///
/// 只保留目录 / 视频 / 音频 / 没有归属的字幕 —— 与浏览页同一口径，
/// `.txt`/`.docx` 之类在内核列目录时已经滤掉了，这里再兜一层，
/// 免得首页比浏览页多出一堆点不开的东西。
List<MediaEntry> homeRows(DirectoryListing listing) => listing.browsable;

/// 筛选条上要显示的项：`null` 表示「全部」。
///
/// 只有一块来源时不需要切换按钮 —— 一个选项的筛选条只会白占一行高度。
bool showSourceFilter(int sourceCount) => sourceCount > 1;
