import 'package:flutter/foundation.dart';

import '../data/models.dart';

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

  /// 整张播放列表。返回的是只读视图，调用方不要就地改。
  ///
  /// 曾经每次访问都 `List.unmodifiable(_items)` 复制一遍，而全仓没有一处
  /// 读它 —— 连播时每切一集就可能复制一次几百项的列表。这里直接交出去，
  /// 由类型（`List<MediaEntry>` 只暴露读方法）和约定共同约束。
  List<MediaEntry> get items => _items;
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

  String get title {
    final c = current;
    if (c == null) return '';
    return c.name;
  }
}
