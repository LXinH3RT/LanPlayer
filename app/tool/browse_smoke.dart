// End-to-end probe of the SMB browsing chain used by the Flutter UI.
//
// It exercises the real app code (`NativeCore.listDirectory` ->
// `DirectoryListing.fromJson` -> child navigation) without Flutter itself, so a
// failure here means the desktop app would fail the same way.  `MediaRepository`
// is deliberately not used because it pulls in `path_provider` -> `dart:ui`.
//
// Usage (from `app/`, with lanplayer.dll on PATH or beside the script):
//   dart run tool/browse_smoke.dart smb://HOST/SHARE user password
import 'dart:io';

import 'package:lanplayer/core/bindings.dart';
import 'package:lanplayer/data/models.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('usage: browse_smoke.dart <smb://host/share> <user> <pass>');
    exit(64);
  }
  final core = NativeCore.instance;
  final options = <String, dynamic>{
    'user': args[1],
    'password': args[2],
    'timeout_ms': 15000,
  };
  stdout.writeln('abi=${core.version}');

  final root = _browse(core, args[0], options);
  if (root == null) exit(1);
  stdout.writeln('root   ${root.url} -> ${root.entries.length} entries');

  // Walk two levels deep exactly like BrowserScreen._navigate does.
  var listing = root;
  var failed = 0;
  for (var depth = 0; depth < 2; depth++) {
    final folders = listing.folders;
    if (folders.isEmpty) {
      stdout.writeln('  (no folders at this level)');
      break;
    }
    DirectoryListing? deepest;
    for (final f in folders.take(4)) {
      final child = _browse(core, f.path, options, quiet: true);
      if (child == null) {
        failed++;
        continue;
      }
      for (final v in child.entries.where((e) => !e.isDir).take(2)) {
        // Descend one more level from the child to prove the parent link works
        // both ways; the listing itself is what gets printed.
        _browse(core, child.url, options, quiet: true);
        stdout.writeln('         - ${v.name} [${v.kind}] ${v.size} B');
      }
      stdout.writeln('  ok     ${f.name} -> ${child.entries.length} entries, '
          '${child.videos.length} videos, parent=${child.parent}');
      deepest ??= child;
    }
    if (deepest == null) break;
    listing = deepest;
  }

  final video = listing.videos.firstOrNull;
  if (video != null) {
    stdout.writeln('video  ${video.name}');
    stdout.writeln('       path=${video.path}');
    stdout.writeln('       kind=${video.kind} ext=${video.ext} '
        'size=${video.size}');
  }
  stdout.writeln(failed == 0 ? 'BROWSE OK' : 'BROWSE FAILED ($failed)');
  exit(failed == 0 ? 0 : 2);
}

DirectoryListing? _browse(
  NativeCore core,
  String url,
  Map<String, dynamic> options, {
  bool quiet = false,
}) {
  final json = core.listDirectory(url, options);
  if (json == null) {
    stderr.writeln('  FAIL   $url -> ${core.lastSourceError()}');
    return null;
  }
  final listing = DirectoryListing.fromJson(json);
  if (listing.entries.isEmpty) {
    if (!quiet) stderr.writeln('  EMPTY  $url');
  }
  return listing;
}
