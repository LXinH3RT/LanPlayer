import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/home_screen.dart';

/// 首页来源列表的缓存失效契约。
///
/// 回归背景（0.1.8 安卓 release 包）：首页那一帧的来源列表为空时把
/// `buildHomeSources` 的结果缓存了下来，缓存判据是「两个 store 的 List 字段
/// 是不是同一个实例」。可这两个字段是固定的同一个 List，增删都在原地做，
/// `identical` 永远成立 —— 缓存于是永不失效。用户加完本地文件夹，首页仍然
/// 显示「还没有内容」，重启也一样（每次启动都先按空列表缓存一遍）。
///
/// 这组测试锁住的是：**内容变了，首页必须跟着变**，而不是「同一个列表实例」。
void main() {
  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
  });

  LocalFolder folder(String id, String path) => LocalFolder(
        id: id,
        label: id,
        path: path,
      );

  testWidgets('首页先按空状态渲染过，之后加本地文件夹仍会长出来', (tester) async {
    // 关键时序：先让首页拿到「空来源」并缓存下来。
    ServerStore.instance.debugSeed(const []);
    LocalFolderStore.instance.debugSeed(const []);

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    expect(find.text('还没有内容'), findsOneWidget);

    // 用户加了一个本地文件夹。store 原地 add，列表实例不变。
    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      folder('dir-1', '/sdcard/Movies'),
    ]);
    await tester.pump();
    await tester.pump();

    // 空状态必须消失 —— 这就是 release 包里没发生的那一步。
    expect(find.text('还没有内容'), findsNothing);
    expect(find.text('dir-1'), findsOneWidget);
  });

  testWidgets('移除最后一个来源后回到空状态', (tester) async {
    ServerStore.instance.debugSeed(const []);
    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      folder('dir-1', '/sdcard/Movies'),
    ]);

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    expect(find.text('还没有内容'), findsNothing);

    LocalFolderStore.instance.debugSeed(const []);
    await tester.pump();
    await tester.pump();

    expect(find.text('还没有内容'), findsOneWidget);
  });

  testWidgets('服务器那一侧同样按内容失效', (tester) async {
    ServerStore.instance.debugSeed(const []);
    LocalFolderStore.instance.debugSeed(const []);

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    expect(find.text('还没有内容'), findsOneWidget);

    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      folder('dir-2', '/sdcard/Movies'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('还没有内容'), findsNothing);
  });
}
