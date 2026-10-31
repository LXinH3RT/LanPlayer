import 'package:flutter/foundation.dart';

import 'stores.dart';

/// 一个被收进首页的本机路径：一块目录，或者单个文件。
///
/// SMB 服务器存在 `servers.json`，本机路径单独存 `folders.json`：两边的
/// 生命周期互不牵连，删掉一台服务器不会连带清掉别处的本地入口。
class LocalFolder {
  LocalFolder({
    required this.id,
    required this.label,
    required this.path,
    this.isFile = false,
    DateTime? createdAt,
    this.lastUsedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String label;
  String path;

  /// 单文件来源。老记录没有这个字段，按目录处理。
  bool isFile;

  DateTime createdAt;
  DateTime? lastUsedAt;

  String get rootUrl => 'file://$path';

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'path': path,
        'isFile': isFile,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastUsedAt': lastUsedAt?.millisecondsSinceEpoch,
      };

  factory LocalFolder.fromJson(Map<String, dynamic> j) => LocalFolder(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        path: j['path'] as String? ?? '',
        isFile: j['isFile'] == true,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(_intValue(j['createdAt']) ?? 0),
        lastUsedAt: j['lastUsedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                _intValue(j['lastUsedAt']) ?? 0),
      );

  /// 容忍数字、数字字符串与 ISO-8601 时间戳：一条老记录写坏了，
  /// 也不该让整个文件夹列表读不出来。
  static int? _intValue(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return int.tryParse(raw) ??
          DateTime.tryParse(raw)?.millisecondsSinceEpoch;
    }
    return null;
  }
}

/// 首页左侧那半边的来源：本机文件夹。
///
/// 这里特意不叫「最近打开」之类的名字 —— 存下来的就是用户放上首页的目录，
/// 顺序即添加顺序，不按使用时间重排，找东西的时候位置不会乱跳。
/// 本机路径列表。
///
/// 与 [ServerStore] 一样是可监听的：磁盘读取可能晚于首页第一帧，读完要通知
/// 界面重建。
class LocalFolderStore extends ChangeNotifier {
  LocalFolderStore._();
  static final LocalFolderStore instance = LocalFolderStore._();

  static const _file = 'folders.json';

  final List<LocalFolder> folders = <LocalFolder>[];
  bool _loaded = false;

  /// 已经读过磁盘。首页用它区分「真的没有来源」与「还没读完」。
  bool get loaded => _loaded;

  /// 测试用：直接置成「已读完」并给定内容，不碰磁盘。
  ///
  /// 单独 pump 首页的 widget 测试没有 [main] 里的 `_boot()`，缺这个入口就
  /// 只能看到「还没读完」留下的空白。
  @visibleForTesting
  void debugSeed(List<LocalFolder> items) {
    folders
      ..clear()
      ..addAll(items);
    _loaded = true;
    notifyListeners();
  }

  /// 测试用：回到「还没读磁盘」的状态。
  @visibleForTesting
  void debugReset() {
    folders.clear();
    _loaded = false;
  }

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    final list = (json['folders'] as List?) ?? const [];
    folders.clear();
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final f = LocalFolder.fromJson(raw);
        if (f.path.isEmpty) continue;
        folders.add(f);
      } catch (_) {
        // 一条读不出来的记录不能藏起其它所有文件夹。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  LocalFolder? byId(String id) {
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  LocalFolder? byPath(String path) {
    for (final f in folders) {
      if (f.path == path) return f;
    }
    return null;
  }

  /// 本地目录的 id 生成器。
  ///
  /// 只用毫秒时间戳会在「同一次点击里加两个目录」时撞车（两台机械盘挂载
  /// 点连着加就是这样），后加的那条会把前一条覆盖掉。补一个进程内单调
  /// 递增的序号，既不引入随机性也保证唯一。
  static int _idSeq = 0;

  static String _newId(String prefix) =>
      '$prefix-${DateTime.now().millisecondsSinceEpoch}-${_idSeq++}';

  /// 加入首页。同一个路径重复添加时只更新名字，不产生第二条记录 ——
  /// 否则首页会出现两块内容完全一样的目录。
  Future<LocalFolder> add({
    required String label,
    required String path,
    bool isFile = false,
  }) async {
    final existing = byPath(path);
    if (existing != null) {
      existing.label = label;
      existing.isFile = isFile;
      await _save();
      return existing;
    }
    final f = LocalFolder(
      id: _newId('dir'),
      label: label,
      path: path,
      isFile: isFile,
    );
    folders.add(f);
    await _save();
    return f;
  }

  Future<void> remove(String id) async {
    folders.removeWhere((f) => f.id == id);
    await _save();
  }

  Future<void> rename(String id, String label) async {
    final f = byId(id);
    if (f == null) return;
    f.label = label;
    await _save();
  }

  Future<void> touch(String id) async {
    final f = byId(id);
    if (f == null) return;
    f.lastUsedAt = DateTime.now();
    await _save();
  }

  Future<void> _save() async {
    await AppStorage.writeJson(_file, {
      'version': 1,
      'folders': folders.map((f) => f.toJson()).toList(),
    });
    notifyListeners();
  }
}
