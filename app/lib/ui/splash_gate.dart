import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// 启动动画的默认参数。
class SplashDefaults {
  /// 图标至少展示这么久。移动端进程启动（引擎起来、Dart 起来、第一帧）本来
  /// 就要几百毫秒，这里补到 1.2 s，让动画有个完整的一次，而不是闪一下就没。
  static const Duration minimum = Duration(milliseconds: 1200);

  /// 图标淡出、首页淡入的时长。
  static const Duration fade = Duration(milliseconds: 260);

  /// 图标从无到有的时长。
  static const Duration entrance = Duration(milliseconds: 520);
}

enum _Phase { running, fading, content }

/// 启动闸门：先画图标动画，同时把首页建起来加载数据，动画走完再把首页亮出来。
///
/// 之前 `main()` 是「先把四个 store 全部 await 完，再 runApp」，这段时间屏幕
/// 上只有系统那张空白启动图，iPad 上要停一两秒，用户看到的就是「点开没反应」。
/// 现在第一帧立刻出图标，store 与首页的目录请求都在后台跑；两者都完成后才切换。
///
/// 首页从一开始就挂在 [Stack] 底层（只是被图标盖住），所以它的 `initState`
/// 里的目录请求与启动动画是同时开始的 —— 动画放完时列表通常已经在了。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.boot,
    required this.builder,
    this.onReady,
    this.minimum = SplashDefaults.minimum,
    this.enabled = true,
  });

  /// 启动阶段的后台初始化（读 store、准备存储目录）。允许耗时，也允许抛错。
  final Future<void> Function() boot;

  /// 启动完成后要显示的界面（首页）。
  final WidgetBuilder builder;

  /// 界面真正显示出来之后回调一次，用于跑验证用的自动打开等钩子。
  final VoidCallback? onReady;

  /// 图标至少展示多久。
  final Duration minimum;

  /// 关掉时直接进内容（桌面端与纯 widget 测试）。关掉不影响 [boot] 执行。
  final bool enabled;

  @override
  State<SplashGate> createState() => SplashGateState();

  /// 图标与首页的稳定 key，供测试与截图脚本定位。
  static const Key splashKey = Key('splash');
  static const Key contentKey = Key('splash-content');}

class SplashGateState extends State<SplashGate> {
  _Phase _phase = _Phase.running;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _phase = _Phase.content;
      unawaited(_bootOnly());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
      return;
    }
    unawaited(_run());
  }

  Future<void> _bootOnly() async {
    try {
      await widget.boot();
    } catch (e) {
      debugPrint('LanPlayer boot failed: $e');
    }
  }

  Future<void> _run() async {
    final deadline = Future<void>.delayed(widget.minimum);
    await _bootOnly();
    await deadline;
    if (!mounted) return;
    setState(() => _phase = _Phase.fading);
    await Future<void>.delayed(SplashDefaults.fade);
    if (!mounted) return;
    setState(() => _phase = _Phase.content);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(
      key: SplashGate.contentKey,
      child: widget.builder(context),
    );
    if (_phase == _Phase.content) return content;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 首页一直在下游加载，动画只是盖在上面。
        content,
        AbsorbPointer(
          child: AnimatedOpacity(
            opacity: _phase == _Phase.fading ? 0 : 1,
            duration: SplashDefaults.fade,
            curve: Curves.easeOut,
            child: const SplashView(key: SplashGate.splashKey),
          ),
        ),
      ],
    );
  }
}

/// 图标 + 名字 + 副标题，静态画面；入场动画只跑一次。
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    // Material，而不是 ColoredBox：没有它，Text 拿不到默认文本样式，
    // Flutter 会退回那个「黄色双下划线」的兜底样式，几行标题下面会挂一道黄线。
    return Material(
      color: LanPlayerTheme.surface,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: SplashDefaults.entrance,
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double t, Widget? child) {
            return Opacity(
              opacity: t,
              child: Transform.scale(
                scale: 0.88 + 0.12 * t,
                child: child,
              ),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Image.asset(
                'assets/branding/splash_logo.png',
                width: 104,
                height: 104,
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(height: 22),
              const Text(
                'LanPlayer',
                style: TextStyle(
                  fontFamily: LanPlayerTheme.fontFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '局域网播放器',
                style: TextStyle(
                  fontFamily: LanPlayerTheme.fontFamily,
                  fontSize: 13,
                  letterSpacing: 1.6,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
