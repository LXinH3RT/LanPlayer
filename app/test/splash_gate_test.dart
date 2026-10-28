import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/splash_gate.dart';

/// 造一个可以手动完成（或永不完成）的 boot，用来观察启动闸门的行为。
class _Boot {
  final Completer<void> _c = Completer<void>();
  int calls = 0;

  Future<void> call() {
    calls++;
    return _c.future;
  }

  void finish() {
    if (!_c.isCompleted) _c.complete();
  }

  void fail(Object e) {
    if (!_c.isCompleted) _c.completeError(e);
  }
}

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: child,
    );

void main() {
  testWidgets('图标先出现，初始化没完成前一直挡着内容', (WidgetTester tester) async {
    final boot = _Boot();
    await tester.pumpWidget(_app(SplashGate(
      boot: boot.call,
      minimum: const Duration(milliseconds: 600),
      builder: (_) => const Text('首页'),
    )));

    expect(find.byKey(SplashGate.splashKey), findsOneWidget);
    // 内容其实已经在树里（它在下游加载），只是被启动画面盖住。
    expect(find.byKey(SplashGate.contentKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(SplashGate.splashKey), findsOneWidget);

    // boot 完成了，但最小展示时长还没到，仍然不该露出内容。
    boot.finish();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(SplashGate.splashKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(SplashGate.splashKey), findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('初始化比最小时长更快时，图标仍然停满一个完整时长',
      (WidgetTester tester) async {
    final boot = _Boot();
    await tester.pumpWidget(_app(SplashGate(
      boot: boot.call,
      minimum: const Duration(milliseconds: 600),
      builder: (_) => const Text('首页'),
    )));

    boot.finish(); // 立刻成功
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(SplashGate.splashKey), findsOneWidget,
        reason: '不能因为初始化快就只闪一下图标');

    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byKey(SplashGate.splashKey), findsNothing);
  });

  testWidgets('初始化抛错也要把内容放出来，不能永远卡在图标上',
      (WidgetTester tester) async {
    final boot = _Boot();
    await tester.pumpWidget(_app(SplashGate(
      boot: boot.call,
      minimum: const Duration(milliseconds: 100),
      builder: (_) => const Text('首页'),
    )));

    boot.fail(StateError('状态目录不可写'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(SplashGate.splashKey), findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('内容显示后回调一次 onReady', (WidgetTester tester) async {
    final boot = _Boot();
    var ready = 0;
    await tester.pumpWidget(_app(SplashGate(
      boot: boot.call,
      minimum: const Duration(milliseconds: 100),
      onReady: () => ready++,
      builder: (_) => const Text('首页'),
    )));
    expect(ready, 0, reason: '图标还在的时候不该跑启动后的钩子');

    boot.finish();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(ready, 1);
  });

  testWidgets('enabled 为 false 时直接显示内容，仍然执行初始化',
      (WidgetTester tester) async {
    final boot = _Boot();
    var ready = 0;
    await tester.pumpWidget(_app(SplashGate(
      boot: boot.call,
      enabled: false,
      onReady: () => ready++,
      builder: (_) => const Text('首页'),
    )));
    await tester.pump();

    expect(find.byKey(SplashGate.splashKey), findsNothing);
    expect(find.text('首页'), findsOneWidget);
    expect(boot.calls, 1, reason: '桌面端跳过动画也要读 store');
    await tester.pumpAndSettle();
    expect(ready, 1);
  });
}
