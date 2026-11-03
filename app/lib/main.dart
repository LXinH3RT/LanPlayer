import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/boot_status.dart';
import 'data/folders.dart';
import 'data/location.dart';
import 'data/models.dart';
import 'data/probe.dart';
import 'data/progress.dart';
import 'data/repository.dart';
import 'data/stores.dart';
import 'data/trace.dart';
import 'player/playlist.dart';
import 'ui/browser_screen.dart';
import 'ui/home_screen.dart';
import 'ui/player_screen.dart';
import 'ui/server_edit_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/splash_gate.dart';
import 'ui/startup_reset.dart';
import 'ui/theme.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 状态目录优先：必须在任何 store 读取之前设好。
  final pinnedDir = probeFlag('LANPLAYER_STATE_DIR');
  if (pinnedDir != null) {
    AppStorage.directoryOverride = Directory(pinnedDir);
  }
  // 排查开关：把导航栈的每一次 push/pop、以及前后台与尺寸变化写进状态目录
  // 下的 trace.log，或者在 `LANPLAYER_TRACE_PATH` 指定一个可写的绝对路径
  // （iPad 上拿不到应用容器的绝对路径时，用它指到 Documents 里）。
  if (traceEnabled) {
    WidgetsBinding.instance.addObserver(TraceLifecycle());
    // 指针事件要趁早装上：弹层被点掉还是被拖掉，只有这一路能分开。
    installPointerTrace();
    // 帧耗时：区分「内核送帧偏晚」与「光栅线程错过 vsync」。
    installFrameTrace();
    final directPath = probeFlag('LANPLAYER_TRACE_PATH');
    if (directPath != null && directPath.isNotEmpty) {
      traceTo(directPath);
      trace('boot trace-path=$directPath');
    }
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
  // 失败要能被首页看见：状态目录打不开时下面的 store 全部读不成，界面若只
  // 停在空白上，用户既不知道发生了什么也没法自救。
  BootStatus.instance.retry = _boot;
  try {
    final dir = await AppStorage.directory();
    if (traceEnabled && !traceHasFile) {
      traceTo('${dir.path}/trace.log');
      trace('boot storage=${dir.path}');
    }
    // ignore: avoid_print
    print(
        "LanPlayer storage: ${dir.path} (servers=${ServerStore.instance.servers.length})");
  } catch (e) {
    // ignore: avoid_print
    print("LanPlayer storage error: $e");
    BootStatus.instance.failed(e);
    return;
  }
  try {
    await Future.wait<void>([
      ServerStore.instance.load(),
      LocalFolderStore.instance.load(),
      SettingsStore.instance.load(),
      ProgressStore.instance.load(),
    ]);
  } catch (e) {
    // ignore: avoid_print
    print("LanPlayer store error: $e");
    BootStatus.instance.failed(e);
    return;
  }
  // 外观设置读盘之后立刻套用：否则启动那一下会先按默认黑色画出来，
  // 选了「白色」的用户会看到界面闪一次黑再变白。
  ThemeController.instance.apply(SettingsStore.instance.value.themeMode);
  BootStatus.instance.succeeded();
  // ignore: avoid_print
  print("LanPlayer loaded: servers=${ServerStore.instance.servers.length} "
      "folders=${LocalFolderStore.instance.folders.length}");
}

/// store 读完之后的验证钩子：自动打开文件 / 进共享 / 打开添加服务器页。
///
/// 这些全部靠环境变量或 `--dart-define` 触发，正常运行时一个都不生效。
void _runProbes() {
  // 冷启动一律从首页开始：进程被系统回收后重新进来时，引擎可能把上次的导航栈
  // 一并恢复，于是「一开就回到上次那个播放页」。那个页面此刻的 SMB 源往往已经
  // 不可达，用户看到的是一句连接失败，还得先返回一次。上次看到哪儿由
  // ProgressStore 记着（首页该行会显示「已看 xx%」），界面不需要恢复。
  //
  // 正常启动时栈里本来就只有首页，这一步是空操作。
  final navigator = appNavigatorKey.currentState;
  if (navigator != null) {
    final popped = collapseToHome(navigator);
    if (popped > 0) {
      trace('startup collapsed $popped route(s) back to home');
    }
  }
  // Convenience hook for desktop testing (and for the CI screenshot check):
  //   set LANPLAYER_OPEN=D:\video.mkv
  // opens that file in the player right after startup.
  final autoOpen = probeFlag('LANPLAYER_OPEN');
  if (autoOpen != null && autoOpen.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final resolved = await _resolveProbePath(autoOpen);
      _openLocalFile(resolved);
    });
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
    final label = LpScheme.isFileUrl(url)
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

/// 把探针里的相对路径解析成绝对路径。
///
/// 移动端每次重装，应用数据容器的 UUID 都会变，`--dart-define` 里写死的绝对
/// 路径下次就失效了。所以 `LANPLAYER_OPEN=/Documents/x.mp4` 这种写法按「应用
/// 文档目录」解析：容器换了也照样找得到同一个文件。桌面端本来就是绝对路径，
/// 只有以 `/` 开头且不是 Windows 盘符时才在这里改写。
Future<String> _resolveProbePath(String target) async {
  if (!target.startsWith('/')) return target;
  if (!Platform.isIOS && !Platform.isAndroid) return target;
  final docs = await getApplicationDocumentsDirectory();
  // getApplicationDocumentsDirectory() 在移动端本来就以 /Documents 结尾，
  // 探针写成 /Documents/x.mp4 时再拼一次就成了 .../Documents/Documents/x.mp4。
  // 两种写法都认：先去掉前导斜杠，再剥掉与文档目录重名的那一段。
  var relative = target.replaceFirst(RegExp(r'^/+'), '');
  if (relative.startsWith('Documents/')) {
    relative = relative.substring('Documents/'.length);
  }
  return '${docs.path}/$relative';
}

void _openLocalFile(String target) {
  final isNetwork = LpScheme.isSmbUrl(target);
  final name = target.split(RegExp(r'[\\/]')).last;
  final url = isNetwork
      ? target
      : LpScheme.fileUrl(target.replaceAll(RegExp(r'\\'), '/'));
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
    // 外观设置改了要立刻生效，所以根节点订阅主题控制器：只有 MaterialApp
    // 这一层跟着换主题，播放页、目录页不会被牵连重建。
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: appNavigatorKey,
        // 排查开关打开时把导航栈的每一次变化记进 trace.log，
        // 用来分辨「路由是被谁弹掉的」。
        navigatorObservers:
            traceEnabled ? <NavigatorObserver>[TraceObserver()] : const [],
        title: 'LanPlayer',
        debugShowCheckedModeBanner: false,
        // 深浅色两套都给，具体用哪一套由「设置 → 外观」决定：
        // 默认黑色（深色是播放主场景），也可以选白色或跟随系统。
        theme: LanPlayerTheme.light(),
        darkTheme: LanPlayerTheme.dark(),
        themeMode: ThemeController.toThemeMode(mode),
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
      ),
    );
  }
}
