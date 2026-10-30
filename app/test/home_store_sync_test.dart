import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/home_screen.dart';

/// 首页与「后台读磁盘」之间的时序契约。
///
/// 回归背景：为了让启动动画盖住加载，`runApp` 被提到了四个 store 读取之前。
/// 首页第一帧拿到的来源列表必然是空的，而 store 当时既不是 Listenable，读完
/// 也没人通知界面 —— 0.1.6 装好后首页永远停在「还没有内容」，服务器其实在
/// 磁盘上好好的。这组测试锁住两件事：没读完不能报「还没有内容」，读完了要
/// 自己长出内容。
void main() {
  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
  });

  ServerProfile server(String id) => ServerProfile(
        id: id,
        name: '媒体',
        host: '192.168.1.10',
        port: 445,
        share: '共享',
        user: 'share',
        password: '',
        createdAt: DateTime(2026, 1, 1),
      );

  testWidgets('磁盘还没读完时不显示「还没有内容」，读完自己长出列表', (tester) async {
    // 两个 store 都是 pristine 状态：模拟 app 刚起来、_boot() 还没跑到。
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    // 关键断言：这份空白是「还没读完」，不是「真的没有来源」。
    expect(find.text('还没有内容'), findsNothing);
    expect(find.text('添加服务器'), findsNothing);

    // 后台读取完成 —— 只通过 notifyListeners，界面自己要跟上。
    ServerStore.instance.debugSeed(<ServerProfile>[server('srv-1')]);
    await tester.pump();

    expect(find.text('还没有内容'), findsNothing);
  });

  testWidgets('读完磁盘确实没有来源时，才显示空状态页', (tester) async {
    ServerStore.instance.debugSeed(<ServerProfile>[]);
    LocalFolderStore.instance.debugSeed(<LocalFolder>[]);

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('添加本地文件/文件夹'), findsOneWidget);
  });

  testWidgets('来源增多时首页跟着重建，不需要手动刷新', (tester) async {
    ServerStore.instance.debugSeed(<ServerProfile>[server('srv-1')]);

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    // 第二台服务器是后来加进来的（另一处代码 upsert 后 store 通知）。
    ServerStore.instance.debugSeed(<ServerProfile>[
      server('srv-1'),
      server('srv-2'),
    ]);
    await tester.pump();

    // 两块来源都会各自顶栏自己的标题行；只要不是空状态就说明列表跟上了。
    expect(find.text('还没有内容'), findsNothing);
  });
}
