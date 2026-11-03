import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/boot_status.dart';
import 'package:lanplayer/ui/home_screen.dart';

/// 启动失败时首页不能停在空白上。
///
/// 状态目录打不开（磁盘满、权限被收回）时四个 store 一个都读不成，
/// 首页以前画的是 `SizedBox.expand()` —— 用户看到的是一片空白，既没有说明
/// 也没有可以点的东西。这里钉住「有话说、能重试」这两件事。
void main() {
  tearDown(BootStatus.instance.reset);

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
  }

  testWidgets('还没读完时保持空白，不提前报错', (tester) async {
    await pumpHome(tester);
    expect(find.text('打不开配置目录'), findsNothing);
    expect(find.text('还没有内容'), findsNothing);
  });

  testWidgets('启动失败时说明原因并给重试按钮', (tester) async {
    BootStatus.instance.failed(StateError('no writable state directory: EACCES'));
    await pumpHome(tester);

    expect(find.text('打不开配置目录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 原因原文要露出来，否则用户和日志里都对不上是什么错。
    expect(find.textContaining('no writable state directory'), findsOneWidget);
  });

  testWidgets('重试按钮调到挂上来的启动流程', (tester) async {
    var retried = 0;
    BootStatus.instance.failed(StateError('boom'));
    BootStatus.instance.retry = () async {
      retried += 1;
    };
    await pumpHome(tester);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('重试成功之后回到空状态而不是继续报错', (tester) async {
    BootStatus.instance.failed(StateError('boom'));
    await pumpHome(tester);
    expect(find.text('打不开配置目录'), findsOneWidget);

    // 成功路径只清掉失败，来源仍然是空的（这份测试没有真 store），
    // 于是应当落到「还没有内容」。
    BootStatus.instance.succeeded();
    await tester.pump();
    expect(find.text('打不开配置目录'), findsNothing);
  });
}
