import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'stores.dart';

/// Where the user stopped in one file.
class ProgressEntry {
  ProgressEntry({
    required this.key,
    required this.positionUs,
    required this.durationUs,
    required this.updatedAt,
  });

  String key;
  int positionUs;
  int durationUs;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'key': key,
        'position_us': positionUs,
        'duration_us': durationUs,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  /// Tolerant on purpose: a hand-edited or older file must not throw away the
  /// whole history (only this entry).
  static ProgressEntry? fromJson(Map<String, dynamic> j) {
    final key = j['key'] as String? ?? '';
    final pos = _int(j['position_us']);
    final dur = _int(j['duration_us']);
    if (key.isEmpty || pos == null || dur == null) return null;
    return ProgressEntry(
      key: key,
      positionUs: pos,
      durationUs: dur,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          _int(j['updated_at']) ?? DateTime.now().millisecondsSinceEpoch),
    );
  }

  static int? _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}

/// Remembers the playback position per file so re-opening a video continues
/// where the user stopped instead of starting over.
///
/// The key is the entry path exactly as the browser hands it over
/// (`smb://host/share/dir/file.mkv` or `file:///D:/video.mkv`) — never the
/// credentialised URL, so the SMB password does not end up in `progress.json`.
class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  static const _file = 'progress.json';

  /// Anything below this is "just started": resuming would be noise.
  static const Duration minResume = Duration(seconds: 8);

  /// Do not resume into the credits: a file within this of its end restarts.
  static const Duration tailGuard = Duration(seconds: 15);

  /// Newest-first cap so the file cannot grow without bound on a big library.
  static const int maxEntries = 300;

  final Map<String, ProgressEntry> _entries = <String, ProgressEntry>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final json = await AppStorage.readJson(_file);
    final list = (json['entries'] as List?) ?? const [];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final e = ProgressEntry.fromJson(raw);
        if (e != null) {
          // Older builds stored the credentialised URL; re-key it on load.
          final safe = sanitizeKey(e.key);
          e.key = safe;
          _entries[safe] = e;
        }
      } catch (_) {
        // Skip one bad record, keep the rest.
      }
    }
    _loaded = true;
  }

  ProgressEntry? entry(String key) => _entries[sanitizeKey(key)];

  /// URLs may carry `user:pass@` (playback needs it, storage must not keep
  /// it). Stripping userinfo here means one file always maps to one history
  /// record and the password never lands in `progress.json`.
  ///
  /// Percent escapes are decoded (except `%2F`) because the core reports
  /// listing paths as raw UTF-8 while a playback URL may arrive
  /// percent-encoded — both must map to the same record.
  static String sanitizeKey(String key) {
    var out = key;
    final schemeEnd = out.indexOf('://');
    if (schemeEnd >= 0) {
      final authorityStart = schemeEnd + 3;
      final pathStart = out.indexOf('/', authorityStart);
      final authorityEnd = pathStart < 0 ? out.length : pathStart;
      final at = out.lastIndexOf('@', authorityEnd);
      if (at >= authorityStart) {
        out = '${out.substring(0, authorityStart)}${out.substring(at + 1)}';
      }
    }
    return _decodePercent(_normalizeFileUrl(out));
  }

  /// `file:///D:/x` and `file://D:/x` are the same file; the browser builds
  /// the second form and hand-written/older records may carry the first.
  static String _normalizeFileUrl(String s) {
    const prefix = 'file:///';
    if (!s.startsWith(prefix) || s.length <= prefix.length) return s;
    final rest = s.substring(prefix.length);
    if (rest.length >= 2 && rest[1] == ':') return 'file://$rest';
    return s;
  }

  static String _decodePercent(String s) {
    if (!s.contains('%')) return s;
    final bytes = BytesBuilder(copy: false);
    final src = utf8.encode(s);
    for (var i = 0; i < src.length; i++) {
      if (src[i] == 0x25 && i + 2 < src.length) {
        final hi = _hex(src[i + 1]);
        final lo = _hex(src[i + 2]);
        if (hi >= 0 && lo >= 0) {
          final value = hi * 16 + lo;
          // Keep separators literal: decoding %2F would change the path.
          if (value != 0x2F) {
            bytes.addByte(value);
            i += 2;
            continue;
          }
        }
      }
      bytes.addByte(src[i]);
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      return s;
    }
  }

  static int _hex(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  /// Position to seek to, or `null` when the file should start from zero.
  int? resumablePosition(String key, int durationUs) {
    final e = _entries[sanitizeKey(key)];
    if (e == null) return null;
    final dur = durationUs > 0 ? durationUs : e.durationUs;
    if (dur <= 0) return null;
    final minUs = minResume.inMicroseconds;
    final tailUs = tailGuard.inMicroseconds;
    if (e.positionUs < minUs) return null;
    if (e.positionUs > dur - tailUs) return null;
    return e.positionUs;
  }

  /// Records the position, or forgets the key when the file is basically
  /// finished (or barely started) so the next open is not "resumed" to 2 s.
  Future<void> save(String key, int positionUs, int durationUs) async {
    key = sanitizeKey(key);
    if (key.isEmpty || durationUs <= 0) return;
    final finished = positionUs >= durationUs - tailGuard.inMicroseconds;
    final trivial = positionUs < minResume.inMicroseconds;
    if (finished || trivial) {
      if (_entries.remove(key) != null) await _flush();
      return;
    }
    final e = _entries[key];
    if (e == null) {
      _entries[key] = ProgressEntry(
        key: key,
        positionUs: positionUs,
        durationUs: durationUs,
        updatedAt: DateTime.now(),
      );
    } else {
      e.positionUs = positionUs;
      e.durationUs = durationUs;
      e.updatedAt = DateTime.now();
    }
    await _flush();
  }

  Future<void> clear(String key) async {
    if (_entries.remove(sanitizeKey(key)) != null) await _flush();
  }

  Future<void> _flush() async {
    final entries = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (entries.length > maxEntries) {
      for (final drop in entries.sublist(maxEntries)) {
        _entries.remove(drop.key);
      }
    }
    try {
      await AppStorage.writeJson(_file, {
        'version': 1,
        'entries': _entries.values.map((e) => e.toJson()).toList(),
      });
    } on FileSystemException catch (_) {
      // Losing a resume point must never interrupt playback.
    }
  }
}
