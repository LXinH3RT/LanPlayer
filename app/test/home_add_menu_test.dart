import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/home_screen.dart';
import 'package:lanplayer/ui/server_edit_screen.dart';

/// 「添加」菜单的顺序契约。
///
/// `showModalBottomSheet` 返回的 future 是路由的 `popped`，在导航栈刚决定
/// pop 时就完成了，可 sheet 的退场动画还要 200ms。iOS 上紧接着 push 新页面
/// 时 UIKit 还在收拾模态视图，新页面会被丢掉 —— 真机上的表现就是「点加号
/// 弹出的二级页面立刻自己收回」。所以这里断言：菜单收干净之前不 push，
/// push 之后页面要能停住。
void main() {
  setUp(() {
    // 单独 pump 首页不会有 main() 里的 _boot()，而空状态页只在「磁盘读完
    // 且确实没有来源」时才出现 —— 先把两个 store 置成读完了的空表。
    ServerStore.instance.debugSeed(const []);
    LocalFolderStore.instance.debugSeed(const []);
  });

  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
  });

  testWidgets('空状态页有「添加服务器」和「添加本地文件/文件夹」两颗按钮', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('添加本地文件/文件夹'), findsOneWidget);
  });

  testWidgets('点添加后先等菜单收回去，再压添加服务器页，且页面停住', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();

    await tester.tap(find.text('添加服务器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 菜单里的三项（空状态页那颗按钮被菜单挡住，但它在树里还在）。
    expect(find.text('填写 IP、共享名与账号密码'), findsOneWidget);

    await tester.tap(find.text('填写 IP、共享名与账号密码'));
    // 推进到 sheet 退场动画的中段（200ms 才结束）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('填写 IP、共享名与账号密码'), findsOneWidget);

    // 关键断言：菜单还在退场的这一刻，不能已经压上新页面 —— iOS 上这就是
    // 「二级页面立刻自己收回」的成因。
    expect(find.byType(ServerEditScreen), findsNothing);

    // 等 sheet 收完 + 页面转场走完。
    await tester.pumpAndSettle();
    expect(find.byType(ServerEditScreen), findsOneWidget);

    // 再往后推一段时间，页面不能自己消失。
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ServerEditScreen), findsOneWidget);
  });
}
