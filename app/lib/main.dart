import 'dart:io';

import 'package:flutter/material.dart';

import 'data/folders.dart';
import 'data/location.dart';
import 'data/models.dart';
import 'data/probe.dart';
import 'data/progress.dart';
import 'data/repository.dart';
import 'data/stores.dart';
import 'player/playlist.dart';
import 'ui/browser_screen.dart';
import 'ui/home_screen.dart';
import 'ui/player_screen.dart';
import 'ui/server_edit_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/splash_gate.dart';
import 'ui/theme.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 状态目录优先：必须在任何 store 读取之前设好。
  final pinnedDir = probeFlag('LANPLAYER_STATE_DIR');
  if (pinnedDir != null) {
    AppStorage.directoryOverride = Directory(pinnedDir);
  }
  // 第一步就把界面挂上去，屏幕立刻有东西（图标动画），不再是系统那张空白
  // 启动图。store 的读取与首页的目录请求都在 SplashGate 后面同时进行。
  runApp(const LanPlayerApp(boot: _boot));
}

/// 启动阶段的后台初始化：定位可写的状态目录，再把四个 store 读进内存。
///
/// 失败不抛给上层 —— 拿不到状态目录时宁可当作「没有保存过服务器」，
/// 也好过因为 `throw StateError` 让整个 app 起不来。
Future<void> _boot() async {
  try {
    final dir = await AppStorage.directory();
    // ignore: avoid_print
    print(
        "LanPlayer storage: ${dir.path} (servers=${ServerStore.instance.servers.length})");
  } catch (e) {
    // ignore: avoid_print
    print("LanPlayer storage error: $e");
  }
  await ServerStore.instance.load();
  await LocalFolderStore.instance.load();
  await SettingsStore.instance.load();
  await ProgressStore.instance.load();
  // ignore: avoid_print
  print("LanPlayer loaded: servers=${ServerStore.instance.servers.length} "
      "folders=${LocalFolderStore.instance.folders.length}");
}

/// store 读完之后的验证钩子：自动打开文件 / 进共享 / 打开添加服务器页。
///
/// 这些全部靠环境变量或 `--dart-define` 触发，正常运行时一个都不生效。
void _runProbes() {
  // Convenience hook for desktop testing (and for the CI screenshot check):
  //   set LANPLAYER_OPEN=D:\video.mkv
  // opens that file in the player right after startup.
  final autoOpen = probeFlag('LANPLAYER_OPEN');
  if (autoOpen != null && autoOpen.isNotEmpty) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openLocalFile(autoOpen));
  }

  // Same idea for the browser: jumps straight into a share so the desktop
  // build can be verified (and screenshotted) without clicking through the UI.
  //   LANPLAYER_BROWSE=smb://host/share  LANPLAYER_USER=u  LANPLAYER_PASS=p
  final autoBrowse = probeFlag('LANPLAYER_BROWSE');
  if (autoBrowse != null && autoBrowse.isNotEmpty) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openLocation(autoBrowse));
  }

  // 打开「添加服务器」页，并在需要时自动跑一次局域网扫描 —— 这样桌面端
  // 的扫描界面可以在没有人点鼠标的情况下被验证（截图 / 日志）。
  //   LANPLAYER_UI=add-server  LANPLAYER_AUTOSCAN=1
  if (probeFlag('LANPLAYER_UI') == 'add-server') {
    WidgetsBinding.instance.addPostFrameCallback((_) => _openAddServer());
  }

  // 打开设置页 —— 移动端没有输入注入手段（devicectl 只能截图和启停进程），
  // 「关于」里的版本号只能靠这个开关自己走进去。
  //   LANPLAYER_UI=settings
  if (probeFlag('LANPLAYER_UI') == 'settings') {
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
  }
}

/// 打开设置页。
Future<void> _openSettings() async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    // ignore: avoid_print
    print('LanPlayer settings skipped: navigator not ready');
    return;
  }
  await navigator.push(MaterialPageRoute<void>(
    builder: (_) => const SettingsScreen(),
  ));
}

/// 启动动画是否启用。
///
/// 桌面端关掉：窗口出现的那一刻就能看到列表，动画只会多等一秒。
/// 也留一个开关，方便截图与测试时决定要不要看到它。
bool get _splashEnabled {
  if (probeFlag('LANPLAYER_SPLASH') == '1') return true;
  if (probeFlag('LANPLAYER_SPLASH') == '0') return false;
  return Platform.isIOS || Platform.isAndroid;
}

/// 打开「添加服务器」页。`LANPLAYER_AUTOSCAN=1` 时进去后自动扫描一次。
Future<void> _openAddServer() async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    // ignore: avoid_print
    print('LanPlayer add-server skipped: navigator not ready');
    return;
  }
  final autoScan = probeFlag('LANPLAYER_AUTOSCAN') == '1';
  await navigator.push(MaterialPageRoute<void>(
    builder: (_) => ServerEditScreen(autoScan: autoScan),
  ));
}

Future<void> _openLocation(String url) async {
  // ignore: avoid_print
  print('LanPlayer browse requested: $url');
  final options = <String, dynamic>{
    'user': probeFlag('LANPLAYER_USER') ?? '',
    'password': probeFlag('LANPLAYER_PASS') ?? '',
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
    // 本地目录的完整路径在标题里没有意义（而且截图时会把机器的目录结构一并
    // 拍进去），根目录标题取最后一层目录名；共享地址则保留原样，因为
    // `smb://host/share` 本身就是用户填进去的那一行。
    final segments = url.split('/').where((s) => s.isNotEmpty).toList();
    final label = url.startsWith('file://')
        ? (segments.isEmpty ? url : segments.last)
        : url;
    final location = MediaLocation(
      label: label,
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
  // 网络路径要带上凭据，否则走匿名登录，libsmb2 会报
  // Session setup failed with (0xc000000d) STATUS_INVALID_PARAMETER。
  final location = isNetwork
      ? MediaLocation(
          label: '网络视频',
          rootUrl: target,
          options: <String, dynamic>{
            'user': probeFlag('LANPLAYER_USER') ?? '',
            'password': probeFlag('LANPLAYER_PASS') ?? '',
            'timeout_ms': 15000,
          },
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
  const LanPlayerApp({super.key, this.boot});

  /// 启动阶段的后台初始化；为空时直接从首页开始（widget 测试用）。
  final Future<void> Function()? boot;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'LanPlayer',
      debugShowCheckedModeBanner: false,
      // 深浅色跟随系统：两套都给，交给 MaterialApp 按系统设置挑。只有
      // `theme:` 的话，系统设成浅色的用户会看到一个写死深色的界面。
      theme: LanPlayerTheme.light(),
      darkTheme: LanPlayerTheme.dark(),
      themeMode: ThemeMode.system,
      home: SplashGate(
        boot: boot ?? () async {},
        enabled: boot != null && _splashEnabled,
        onReady: _runProbes,
        builder: (_) => const HomeScreen(),
      ),
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
