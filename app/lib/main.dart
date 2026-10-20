import 'dart:io';

import 'package:flutter/material.dart';

import 'data/location.dart';
import 'data/models.dart';
import 'data/progress.dart';
import 'data/repository.dart';
import 'data/stores.dart';
import 'player/playlist.dart';
import 'ui/browser_screen.dart';
import 'ui/home_screen.dart';
import 'ui/player_screen.dart';
import 'ui/theme.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final dir = await AppStorage.directory();
    // ignore: avoid_print
    print(
        "LanPlayer storage: ${dir.path} (servers=${ServerStore.instance.servers.length})");
  } catch (e) {
    // ignore: avoid_print
    print("LanPlayer storage error: $e");
    // Losing saved servers is worse than using a less pretty default, so fall
    // back to the folder the data actually loads from.
    final fallback = Platform.environment['LANPLAYER_STATE_DIR'];
    if (fallback != null && fallback.isNotEmpty) {
      AppStorage.directoryOverride = Directory(fallback);
    }
  }
  await ServerStore.instance.load();
  await SettingsStore.instance.load();
  await ProgressStore.instance.load();
  // ignore: avoid_print
  print("LanPlayer loaded: servers=${ServerStore.instance.servers.length}");
  runApp(const LanPlayerApp());

  // Convenience hook for desktop testing (and for the CI screenshot check):
  //   set LANPLAYER_OPEN=D:\video.mkv
  // opens that file in the player right after startup.
  final autoOpen = Platform.environment['LANPLAYER_OPEN'];
  if (autoOpen != null && autoOpen.isNotEmpty) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openLocalFile(autoOpen));
  }

  // Same idea for the browser: jumps straight into a share so the desktop
  // build can be verified (and screenshotted) without clicking through the UI.
  //   LANPLAYER_BROWSE=smb://host/share  LANPLAYER_USER=u  LANPLAYER_PASS=p
  final autoBrowse = Platform.environment['LANPLAYER_BROWSE'];
  if (autoBrowse != null && autoBrowse.isNotEmpty) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openLocation(autoBrowse));
  }
}

Future<void> _openLocation(String url) async {
  // ignore: avoid_print
  print('LanPlayer browse requested: $url');
  final options = <String, dynamic>{
    'user': Platform.environment['LANPLAYER_USER'] ?? '',
    'password': Platform.environment['LANPLAYER_PASS'] ?? '',
    'timeout_ms': 15000,
  };
  final repo = MediaRepository();
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    // ignore: avoid_print
    print('LanPlayer browse skipped: navigator not ready');
    return;
  }
  try {
    final listing = await repo.browseUrl(url, options);
    // ignore: avoid_print
    print('LanPlayer browse: ${listing.url} -> ${listing.entries.length} '
        'entries (${listing.folders.length} folders, '
        '${listing.videos.length} videos)');
    for (final e in listing.entries) {
      final p = ProgressStore.instance.entry(e.path);
      final ms = p == null
          ? null
          : ProgressStore.instance.resumablePosition(e.path, p.durationUs);
      final pct = (p == null || ms == null || p.durationUs <= 0)
          ? null
          : (ms * 100 / p.durationUs);
      // ignore: avoid_print
      print('LanPlayer row: ${e.name} path=${e.path} '
          '${p == null ? "no-history" : (ms == null ? "finished" : "${(ms / Duration.microsecondsPerSecond).toStringAsFixed(1)}s pct=${pct!.toStringAsFixed(1)}")}');
    }
    final location = MediaLocation(
      label: url,
      rootUrl: url,
      options: options,
    );
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => BrowserScreen(location: location, initial: listing),
    ));
  } catch (e) {
    // ignore: avoid_print
    print('LanPlayer browse failed: $e');
  }
}

void _openLocalFile(String target) {
  final isNetwork = target.startsWith('smb://');
  final name = target.split(RegExp(r'[\\/]')).last;
  final url =
      isNetwork ? target : 'file://${target.replaceAll(RegExp(r'\\'), '/')}';
  final entry = MediaEntry(
    name: name,
    path: url,
    isDir: false,
    size: 0,
    kind: 'video',
    ext: name.contains('.') ? name.split('.').last : '',
  );
  final playlist = PlaylistController(items: [entry]);
  final location = isNetwork
      ? MediaLocation(
          label: '网络视频',
          rootUrl: target,
          options: const {},
        )
      : MediaLocation.local('本地视频', target);
  appNavigatorKey.currentState?.push(MaterialPageRoute<void>(
    builder: (_) => PlayerScreen(
      location: location,
      playlist: playlist,
      settings: SettingsStore.instance.value,
    ),
  ));
}

class LanPlayerApp extends StatelessWidget {
  const LanPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'LanPlayer',
      debugShowCheckedModeBanner: false,
      theme: LanPlayerTheme.dark(),
      home: const HomeScreen(),
      builder: (context, child) {
        // Subtitles must not be pushed off screen by huge accessibility fonts.
        final scaler =
            MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
