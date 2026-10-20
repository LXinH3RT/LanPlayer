import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Tiny JSON-file persistence layer.
///
/// Writes are atomic (temp file + rename) so a kill during save cannot corrupt
/// the profile list.  The share keys live in plain JSON under the app support
/// directory: see docs/security.md for the threat model and the follow-up work
/// (Keychain / Keystore backed storage).
class AppStorage {
  static Directory? _dir;

  /// Set when the platform support directory is unusable (sandboxed test runs)
  /// so the app can still persist somewhere writable.
  static Directory? directoryOverride;

  static Future<Directory> directory() async {
    final cached = _dir;
    if (cached != null) return cached;

    // Ordered candidates.  The first one that can actually be created wins, so
    // a read-only %APPDATA% (locked-down profile, AppContainer, container image)
    // never makes saved servers disappear.
    final candidates = <Directory>[];

    final pinned = directoryOverride;
    if (pinned != null) candidates.add(pinned);

    // LANPLAYER_STATE_DIR pins the profile folder: portable installs and test
    // environments need to keep servers next to the executable, not in %APPDATA%.
    final env = Platform.environment['LANPLAYER_STATE_DIR'];
    if (env != null && env.isNotEmpty) candidates.add(Directory(env));

    if (pinned == null && (env == null || env.isEmpty)) {
      try {
        final support = await getApplicationSupportDirectory();
        candidates.add(Directory('${support.path}/lanplayer'));
      } catch (_) {
        // path_provider missing or refused: keep going with the fallbacks.
      }
      // Next to the executable: works for portable copies and for sandboxes
      // that only grant write access to the install folder.
      try {
        final exe = File(Platform.resolvedExecutable).parent;
        candidates.add(Directory('${exe.path}/state'));
      } catch (_) {}
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        candidates.add(Directory('$local\\lanplayer'));
      }
      candidates.add(Directory('${Directory.systemTemp.path}/lanplayer'));
    }

    Object? lastError;
    for (final dir in candidates) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        _dir = dir;
        return dir;
      } catch (e) {
        lastError = e;
        // Try a throwaway probe file: exists() can succeed while writes fail.
        try {
          final probe = File('${dir.path}/.write-probe');
          await probe.writeAsString('ok', flush: true);
          await probe.delete();
          _dir = dir;
          return dir;
        } catch (e2) {
          lastError = e2;
        }
      }
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
      // A corrupt file must never brick the app.
      return {'_error': '$e'};
    }
  }

  static Future<void> writeJson(String name, Map<String, dynamic> data) async {
    final dir = await directory();
    final f = File('${dir.path}/$name');
    final tmp = File('${dir.path}/$name.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data),
        flush: true);
    await tmp.rename(f.path);
  }
}

class ServerStore {
  ServerStore._();
  static final ServerStore instance = ServerStore._();

  static const _file = 'servers.json';
  final List<ServerProfile> servers = <ServerProfile>[];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    final list = (json['servers'] as List?) ?? const [];
    servers.clear();
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        servers.add(ServerProfile.fromJson(raw));
      } catch (_) {
        // One unreadable entry must not hide every other saved server.
      }
    }
    _loaded = true;
  }

  ServerProfile? byId(String id) {
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> upsert(ServerProfile profile) async {
    final idx = servers.indexWhere((s) => s.id == profile.id);
    if (idx >= 0) {
      servers[idx] = profile;
    } else {
      servers.add(profile);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    servers.removeWhere((s) => s.id == id);
    await _save();
  }

  Future<void> touch(String id) async {
    final s = byId(id);
    if (s == null) return;
    s.lastUsedAt = DateTime.now();
    await _save();
  }

  Future<void> _save() async {
    await AppStorage.writeJson(_file, {
      'version': 1,
      'servers': servers.map((s) => s.toJson()).toList(),
    });
  }
}

class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();

  static const _file = 'settings.json';
  PlaybackSettings value = PlaybackSettings();
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    value = PlaybackSettings.fromJson(json);
    _loaded = true;
  }

  Future<void> save() async {
    await AppStorage.writeJson(_file, value.toJson());
  }
}
