import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/add_sheet.dart';
import 'package:lanplayer/ui/home_screen.dart';
import 'package:lanplayer/ui/server_edit_screen.dart';

/// 「添加」菜单的遮罩行为。
///
/// 真机上这个菜单会自己收回：日志里每次都是 push 之后约 348 毫秒冒出一个
/// 坐标恰好是 (0,0) 的指针事件，紧跟着 `Navigator.maybePop`。那一片正是
/// 状态栏，手指点不到，是系统补发的幽灵触点。这里钉住两条：**原点上来的
/// 点击不许关菜单**，**真正的点击照常关**。
void main() {
  setUp(() {
    ServerStore.instance.debugSeed(const []);
    LocalFolderStore.instance.debugSeed(const []);
  });

  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
  });

  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.tap(find.text('添加服务器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('填写 IP、共享名与账号密码'), findsOneWidget);
  }

  testWidgets('点遮罩原点（幽灵触点）不关闭菜单', (tester) async {
    await openMenu(tester);

    await tester.tapAt(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('填写 IP、共享名与账号密码'), findsOneWidget);
  });

  testWidgets('点遮罩其它位置照常关闭菜单', (tester) async {
    await openMenu(tester);

    // 左上角是状态栏，右下角是真正「点外面」的位置。
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width - 8, 8));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('填写 IP、共享名与账号密码'), findsNothing);
    // 关掉菜单不等于选中某一项，二级页面不该出现。
    expect(find.byType(ServerEditScreen), findsNothing);
  });

  testWidgets('原点旁边一个像素就算真实点击', (tester) async {
    // 这条是上一条的对照组：如果遮罩在左上角根本收不到点击，上一条会
    // 假绿。真的点在原点旁边一丁点，菜单就该关掉。
    await openMenu(tester);

    await tester.tapAt(const Offset(0.5, 0.5));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('填写 IP、共享名与账号密码'), findsNothing);
  });

  testWidgets('路由类只把原点当幽灵，其它坐标一律放行', (tester) async {
    // 纯坐标判据的回归：判「恰好等于原点」而不是「离原点很近」，
    // 因为真的有人会去点左上角，而那里是状态栏。
    expect(AddSheetRoute.ghostOriginForTest, Offset.zero);
  });
}
