import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Episode recognition for "auto play the next file in this folder".
///
/// Handles the two naming schemes that cover almost every library:
///   S01E02 / s1e2 / 1x02  and  第12集 / EP12 / [12].
final _episodePatterns = <RegExp>[
  RegExp(r'[Ss](\d{1,2})[\s._-]*[Ee](\d{1,3})'),
  RegExp(r'(?<!\d)(\d{1,2})[xX](\d{1,3})(?!\d)'),
  RegExp(r'第\s*(\d{1,4})\s*[集话話]'),
  RegExp(r'\bEP?\s*(\d{1,4})\b', caseSensitive: false),
];

({int season, int episode})? parseEpisode(String name) {
  for (final p in _episodePatterns) {
    final m = p.firstMatch(name);
    if (m == null) continue;
    if (m.groupCount >= 2) {
      final s = int.tryParse(m.group(1) ?? '');
      final e = int.tryParse(m.group(2) ?? '');
      if (e != null) return (season: s ?? 1, episode: e);
    } else {
      final e = int.tryParse(m.group(1) ?? '');
      if (e != null) return (season: 1, episode: e);
    }
  }
  return null;
}

/// The queue the player screen renders and advances through.
class PlaylistController extends ChangeNotifier {
  PlaylistController({required List<MediaEntry> items, int index = 0})
      : _items = List.of(items),
        _index = items.isEmpty ? -1 : index.clamp(0, items.length - 1);

  /// Builds a playlist from one directory listing, starting at [startPath].
  factory PlaylistController.fromListing(
      DirectoryListing listing, String startPath) {
    final videos = listing.videos;
    var idx = videos.indexWhere((v) => v.path == startPath);
    if (idx < 0) idx = 0;
    return PlaylistController(items: videos, index: idx);
  }

  final List<MediaEntry> _items;
  int _index;
  bool autoNext = true;

  List<MediaEntry> get items => List.unmodifiable(_items);
  int get index => _index;
  int get length => _items.length;
  MediaEntry? get current =>
      _index >= 0 && _index < _items.length ? _items[_index] : null;
  bool get hasNext => _index + 1 < _items.length;
  bool get hasPrevious => _index > 0;

  MediaEntry? advance() {
    if (!hasNext) return null;
    _index++;
    notifyListeners();
    return current;
  }

  MediaEntry? previous() {
    if (!hasPrevious) return null;
    _index--;
    notifyListeners();
    return current;
  }

  bool select(String path) {
    final i = _items.indexWhere((v) => v.path == path);
    if (i < 0) return false;
    _index = i;
    notifyListeners();
    return true;
  }

  /// Appends the next episode of the same season when the folder is flat but
  /// the user opened a single file from elsewhere.
  void appendEpisodes(List<MediaEntry> candidates) {
    final cur = current;
    if (cur == null) return;
    final ep = parseEpisode(cur.name);
    if (ep == null) return;
    final extra = candidates
        .where((c) => c.isVideo && !_items.any((e) => e.path == c.path))
        .where((c) {
      final e = parseEpisode(c.name);
      return e != null && e.season == ep.season && e.episode > ep.episode;
    }).toList()
      ..sort((a, b) => (parseEpisode(a.name)?.episode ?? 0)
          .compareTo(parseEpisode(b.name)?.episode ?? 0));
    if (extra.isEmpty) return;
    _items.addAll(extra);
    notifyListeners();
  }

  String get title {
    final c = current;
    if (c == null) return '';
    return c.name;
  }
}
