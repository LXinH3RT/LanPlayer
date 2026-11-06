import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'secret_store.dart';

/// Tiny JSON-file persistence layer.
///
/// Writes are atomic (temp file + rename) so a kill during save cannot corrupt
/// the profile list.  The profile JSON holds no credentials: SMB passwords live
/// in the system vault (Keychain / Keystore / Credential Manager) via
/// `SecretStore`, and only fall back to this file when the vault is
/// unavailable.  See docs/security.md for the threat model.
class AppStorage {
  static Directory? _dir;

  /// Set when the platform support directory is unusable (sandboxed test runs)
  /// so the app can still persist somewhere writable.
  static Directory? directoryOverride;

  /// 测试用：把记住的目录丢掉，好让下一次 [directory] 重新解析。
  ///
  /// 单独一个入口是因为 `_dir` 一旦缓存就一直用，测试之间换了
  /// [directoryOverride] 也读不到新目录（删掉临时目录后写文件直接
  /// `PathNotFoundException`）。
  @visibleForTesting
  static void debugResetDirectory() {
    _dir = null;
  }

  /// 建目录 + 写一个探针文件，两件都成才算这个候选可用。
  ///
  /// 探针必须**无条件**执行：`exists()` / `create()` 成功只说明目录项存在，
  /// 不说明往里写得进文件 —— 只读挂载、配额用完、被沙盒收回写权限都属于
  /// 「目录在但写不进去」。以前探针写在 catch 分支里，正好把要防的那种情况
  /// 漏掉，程序把不可写目录当成可用，之后每次保存都失败。
  static Future<Directory?> _tryDir(Directory dir) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.write-probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> directory() async {
    final cached = _dir;
    if (cached != null) return cached;

    // Ordered candidates.  The first one that can actually be written wins, so
    // a read-only %APPDATA% (locked-down profile, AppContainer, container image)
    // never makes saved servers disappear.
    final pinned = directoryOverride;
    // LANPLAYER_STATE_DIR pins the profile folder: portable installs and test
    // environments need to keep servers next to the executable, not in %APPDATA%.
    final env = Platform.environment['LANPLAYER_STATE_DIR'];
    final useDefaults = pinned == null && (env == null || env.isEmpty);

    final candidates = <FutureOr<Directory?> Function()>[];
    if (pinned != null) candidates.add(() => pinned);
    if (env != null && env.isNotEmpty) candidates.add(() => Directory(env));
    if (useDefaults) {
      // path_provider / resolvedExecutable 都可能抛，所以做成惰性闭包：
      // 抛了只跳过这一项，不影响后面的候选。
      candidates.add(() async {
        try {
          final support = await getApplicationSupportDirectory();
          return Directory('${support.path}/lanplayer');
        } catch (_) {
          return null;
        }
      });
      // Next to the executable: works for portable copies and for sandboxes
      // that only grant write access to the install folder.
      candidates.add(() {
        try {
          final exe = File(Platform.resolvedExecutable).parent;
          return Directory('${exe.path}/state');
        } catch (_) {
          return null;
        }
      });
      candidates.add(() {
        final local = Platform.environment['LOCALAPPDATA'];
        if (local == null || local.isEmpty) return null;
        return Directory('$local\\lanplayer');
      });
      candidates.add(() => Directory('${Directory.systemTemp.path}/lanplayer'));
    }

    Object? lastError;
    for (final candidate in candidates) {
      final dir = await candidate();
      if (dir == null) continue;
      final ok = await _tryDir(dir);
      if (ok != null) {
        _dir = ok;
        return ok;
      }
      lastError = StateError('not writable: ${dir.path}');
    }
    throw StateError('no writable state directory: $lastError');
  }

  static Future<Map<String, dynamic>> readJson(String name) async {
    try {
      final f = File('${(await directory()).path}/$name');
      if (!await f.exists()) return {};
      final text = await f.readAsString();
      if (text.trim().isEmpty) return {};
      final v = jsonDecode(text);
      return v is Map<String, dynamic> ? v : {};
    } catch (e) {
      // 损坏文件不能拖垮启动，但也**不能就地当成空表**：调用方读到的空表
      // 一旦在下次保存时写回去，用户攒了几个月的服务器列表、观看进度就
      // 彻底没了。先把原文件改名存档留证，再返回空表。
      await _quarantine(name);
      return {};
    }
  }

  /// 把读不动的配置文件改名存档，返回存档文件名（成功时）。
  ///
  /// 改名而不是复制，是为了让下一次 `writeJson` 写的是新文件，不会覆盖
  /// 掉用户还能手工抢救的那份。
  static Future<String?> _quarantine(String name) async {
    try {
      final f = File('${(await directory()).path}/$name');
      if (!await f.exists()) return null;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final kept = '$name.corrupt-$stamp';
      await f.rename('${(await directory()).path}/$kept');
      return kept;
    } catch (_) {
      return null;
    }
  }

  /// 每个文件名一条写入队列。
  ///
  /// [writeJson] 把内容写进固定名字的 `$name.tmp` 再 rename，两条写入并发时
  /// 会互相截断同一个临时文件：一方 flush 到一半、另一方已经 rename，落盘的
  /// 就是半截 JSON。下次启动 `readJson` 把它当损坏文件丢掉，用户看到的是
  /// 所有设置回默认值 —— 而这个触发很容易碰到：拖一次音量滑杆每帧都
  /// `save()`。串行化按文件名分队列，不同文件之间仍可并行。
  static final Map<String, Future<void>> _writeChains =
      <String, Future<void>>{};

  static Future<void> writeJson(String name, Map<String, dynamic> data) {
    final prev = _writeChains[name] ?? Future<void>.value();
    final next = prev.then((_) => _writeJsonNow(name, data));
    // 链条本身不能因为某次失败断掉，否则后面所有写入都不会再被执行。
    _writeChains[name] = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _writeJsonNow(
      String name, Map<String, dynamic> data) async {
    final dir = await directory();
    final f = File('${dir.path}/$name');
    final tmp = File('${dir.path}/$name.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data),
        flush: true);
    await tmp.rename(f.path);
  }
}

/// 服务器列表。
///
/// 是 [ChangeNotifier] 而不是普通单例：首页第一帧就可能早于磁盘读取完成
/// （启动动画把 `runApp` 提到 store 加载之前），读完之后必须有人通知界面
/// 重建，否则首页会永远停在「还没有内容」。
class ServerStore extends ChangeNotifier {
  ServerStore._();
  static final ServerStore instance = ServerStore._();

  static const _file = 'servers.json';
  final List<ServerProfile> servers = <ServerProfile>[];
  bool _loaded = false;

  /// [servers] 的 id → profile 索引，见 [_reindex]。
  final Map<String, ServerProfile> _byId = <String, ServerProfile>{};

  /// 内容版本号，每次列表变化自增。
  ///
  /// [servers] 是固定的那个 List 实例，增删改都在原地做，所以外部无法用
  /// 「是不是同一个列表」判断内容变没变。首页按版本号缓存摊平后的来源
  /// 列表，只认这两个数字。
  int _revision = 0;

  /// 内容版本号。只在内容真的变了时才 +1。
  int get revision => _revision;

  /// 磁盘上的列表是否已经读进来了。首页靠它区分「真的没有来源」与
  /// 「还没读完」—— 后者不该显示空状态。
  bool get loaded => _loaded;

  /// 测试用：把 store 直接置成「已读完」并给定内容，不碰磁盘。
  ///
  /// 单独 pump 首页的 widget 测试不会有 [main] 里的 `_boot()`，没有这个入口
  /// 就只能看到「还没读完」留下的空白，测不到真正的空状态与列表。
  @visibleForTesting
  void debugSeed(List<ServerProfile> items) {
    servers
      ..clear()
      ..addAll(items);
    _loaded = true;
    _reindex();
    _revision++;
    notifyListeners();
  }

  /// 测试用：回到「还没读磁盘」的状态。
  @visibleForTesting
  void debugReset() {
    servers.clear();
    _byId.clear();
    _loaded = false;
    _revision++;
  }

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    final list = (json['servers'] as List?) ?? const [];
    servers.clear();
    var migrated = false;
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final profile = ServerProfile.fromJson(raw);
        if (profile.id.isEmpty) continue;
        // 密码在凭据库里。老版本把明文写在同一条记录里，读到就搬过去，
        // 搬完把文件重写一遍（下次启动这条记录里就没有 password 键了）。
        if (profile.hasPasswordStored) {
          await SecretStore.instance.write(profile.id, profile.password);
          migrated = migrated || SecretStore.instance.available;
        } else {
          profile.password =
              await SecretStore.instance.read(profile.id) ?? '';
        }
        servers.add(profile);
      } catch (_) {
        // One unreadable entry must not hide every other saved server.
      }
    }
    _loaded = true;
    _reindex();
    _revision++;
    notifyListeners();
    if (migrated) {
      // 迁移失败（凭据库不可用）就不再重写，保留明文那份还能用。
      await _writeFile();
    }
  }

  /// id → profile 的索引。服务器列表通常只有几个，但 `byId` 在列表构建、
  /// 播放页、封面取图这些热路径上会被反复调用，线性扫描会被放大成 N²。
  void _reindex() {
    _byId
      ..clear()
      ..addEntries(servers.map((s) => MapEntry(s.id, s)));
  }

  ServerProfile? byId(String id) => _byId[id];

  Future<void> upsert(ServerProfile profile) async {
    // 写之前必须先把磁盘上的读进来：否则「还没 load 完就保存」会把已有的
    // 服务器整批覆盖掉（只留下这一条）。
    if (!_loaded) await load();
    final idx = servers.indexWhere((s) => s.id == profile.id);
    if (idx >= 0) {
      servers[idx] = profile;
    } else {
      servers.add(profile);
    }
    _reindex();
    // 密码进凭据库，配置文件里只留 id。
    await SecretStore.instance.write(profile.id, profile.password);
    await _save();
  }

  Future<void> remove(String id) async {
    if (!_loaded) await load();
    servers.removeWhere((s) => s.id == id);
    _reindex();
    await SecretStore.instance.delete(id);
    await _save();
  }

  Future<void> touch(String id) async {
    if (!_loaded) await load();
    final s = byId(id);
    if (s == null) return;
    s.lastUsedAt = DateTime.now();
    await _save();
  }

  Future<void> _save() async {
    await _writeFile();
    _revision++;
    notifyListeners();
  }

  /// 只落盘，不通知。把「写文件」与「通知界面」拆开是因为迁移那一步
  /// （[load] 里把明文密码搬进凭据库后重写文件）不该额外触发一次重建。
  Future<void> _writeFile() async {
    // 凭据库不可用时退回旧做法：密码跟着文件走。宁可留明文也要能用 ——
    // 静默丢密码会让人以为是自己的账号有问题，比这更难查。
    final keepPassword = !SecretStore.instance.available;
    await AppStorage.writeJson(_file, {
      'version': 1,
      'servers':
          servers.map((s) => s.toJson(includePassword: keepPassword)).toList(),
    });
  }
}

class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();

  static const _file = 'settings.json';
  PlaybackSettings value = PlaybackSettings();
  bool _loaded = false;

  /// 落盘动作，测试用注入点。
  ///
  /// 设置页现在会在写盘失败时弹提示（以前完全静默），而「写盘失败」在真机
  /// 上几乎没有可复现的手段 —— 只能在这一层把它换成一个必然抛异常的实现，
  /// 否则那条提示路径永远没有测试覆盖。
  @visibleForTesting
  static Future<void> Function(PlaybackSettings value)? writerOverride;

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    value = PlaybackSettings.fromJson(json);
    _loaded = true;
  }

  Future<void> save() async {
    final override = writerOverride;
    if (override != null) {
      await override(value);
      return;
    }
    await AppStorage.writeJson(_file, value.toJson());
  }
}
