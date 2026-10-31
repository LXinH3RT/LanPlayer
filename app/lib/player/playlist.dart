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

  String get title {
    final c = current;
    if (c == null) return '';
    return c.name;
  }
}
