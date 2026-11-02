import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/startup_reset.dart';

/// 用一颗 [GlobalKey] 拿到 NavigatorState，模拟 `main.dart` 里的 `appNavigatorKey`。
Widget _host(GlobalKey<NavigatorState> key) {
  return MaterialApp(
    navigatorKey: key,
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('第二页'))),
            )),
            child: const Text('首页'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('栈里只有首页时什么都不做', (WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(key));
    await tester.pumpAndSettle();

    expect(collapseToHome(key.currentState!), 0,
        reason: '正常启动时栈里只有首页，不该弹掉任何一层');
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('栈里多出来的一层会被收回首页', (WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(key));
    await tester.pumpAndSettle();

    // 模拟「进程重建时引擎把上次的播放页恢复了回来」：栈里多一页。
    unawaited(key.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('上次的播放页'))),
    )));
    await tester.pumpAndSettle();
    expect(find.text('上次的播放页'), findsOneWidget);

    expect(collapseToHome(key.currentState!), 1);
    await tester.pumpAndSettle();
    expect(find.text('上次的播放页'), findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('多出来的两层一起收回，并如实报数', (WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(key));
    await tester.pumpAndSettle();

    unawaited(key.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('层 0'))),
    )));
    await tester.pumpAndSettle();
    unawaited(key.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('层 1'))),
    )));
    await tester.pumpAndSettle();

    expect(collapseToHome(key.currentState!), 2);
    await tester.pumpAndSettle();
    expect(find.text('层 0'), findsNothing);
    expect(find.text('层 1'), findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });
}
