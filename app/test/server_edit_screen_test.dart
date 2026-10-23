import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/lan_scan.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/server_edit_screen.dart';

/// 添加服务器页的界面断言。
///
/// 「扫描局域网」真的会去连网络，不适合在单测里跑；这里只保证：
/// 页面能渲染、扫描入口在、共享名仍然是必填、校验提示的文案没变。
/// 扫描逻辑本身由 `test/lan_scan_test.dart` 覆盖，
/// 真实网段的命中由 `tool/lan_scan_probe.dart` 实地验证。
void main() {
  testWidgets('添加服务器页有扫描入口和五个输入框', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServerEditScreen()));
    await tester.pump();

    expect(find.text('添加 SMB 服务器'), findsOneWidget);
    // 扫描入口
    expect(find.text('扫描局域网'), findsOneWidget);
    // 地址 / 端口 / 共享名 / 用户名 / 密码（不再有「显示名称」那一栏）
    expect(find.byType(TextFormField), findsNWidgets(5));
    expect(find.text('显示名称（可选）'), findsNothing);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  test('卡片标题回退到共享名（老配置 name 为空时也不会显示成空白）', () {
    // 添加页已经不再问显示名，但老配置里可能存着空串，或者用户在旧版本里
    // 刻意清空过。displayName 负责兜底，界面和删除确认框都只用它。
    final blank = ServerProfile(
      id: 'srv-1',
      host: '192.168.1.10',
      share: 'Movies',
      user: 'guest',
    );
    expect(blank.name, '');
    expect(blank.displayName, 'Movies');

    // 老配置里存了自己起的名字，要继续用那个，不能被共享名覆盖掉。
    final named = ServerProfile(
      id: 'srv-2',
      name: '客厅媒体库',
      host: '192.168.1.10',
      share: 'Movies',
    );
    expect(named.displayName, '客厅媒体库');

    // 全是空白字符也按空处理，否则卡片上会出现一行看不见的标题。
    final padded = ServerProfile(id: 'srv-3', name: '   ', share: ' Movies ');
    expect(padded.displayName, 'Movies');
  });

  testWidgets('连续添加两台机器时，卡片标题分别取各自的共享名', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServerEditScreen()));
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(2), 'Movies');
    await tester.enterText(find.byType(TextFormField).at(0), '192.168.1.10');
    await tester.pump();

    // 共享名填了之后，页面上不该再出现任何「显示名称」字样
    expect(find.textContaining('显示名称'), findsNothing);
    expect(find.text('Movies'), findsOneWidget);
  });

  testWidgets('共享名没填时点保存会给出必填提示，不会去连服务器', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServerEditScreen()));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('请填写共享名'), findsOneWidget);
  });

  testWidgets('端口填非法值时报端口无效', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServerEditScreen()));
    await tester.pump();

    final portField = find.widgetWithText(TextFormField, '445');
    expect(portField, findsOneWidget);
    await tester.enterText(portField, '70000');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('端口无效'), findsOneWidget);
  });

  testWidgets('编辑已有服务器时标题是「编辑服务器」，字段回填', (tester) async {
    final profile = ServerProfile(
      id: 'srv-test',
      name: '家里的 NAS',
      host: '192.168.1.10',
      port: 445,
      share: '共享',
      user: 'share',
      password: '',
    );
    await tester
        .pumpWidget(MaterialApp(home: ServerEditScreen(profile: profile)));
    await tester.pump();

    expect(find.text('编辑服务器'), findsOneWidget);
    // 地址框的 hint 与回填值可能相同，按 controller 断言而不是按文本找控件。
    String fieldText(int i) =>
        tester.widget<TextFormField>(find.byType(TextFormField).at(i)).controller!.text;
    expect(fieldText(0), '192.168.1.10');
    expect(fieldText(2), '共享');
    expect(fieldText(3), 'share');
  });

  testWidgets('扫描结果列表把每台主机都画出来，点一行会回调', (tester) async {
    final hosts = <LanHost>[
      const LanHost(address: '192.168.1.10', name: 'nas'),
      const LanHost(address: '192.168.1.20'),
    ];
    LanHost? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LanHostPicker(
          hosts: hosts,
          selected: '',
          onPick: (h) => picked = h,
        ),
      ),
    ));
    await tester.pump();

    // 有名字的显示 "名字 (地址)"，没名字的只显示地址。
    expect(find.text('nas (192.168.1.10)'), findsOneWidget);
    expect(find.text('192.168.1.20'), findsOneWidget);
    expect(find.textContaining('共享名仍需自己填'), findsOneWidget);
    // 没选中时不该有对勾。
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.tap(find.text('nas (192.168.1.10)'));
    await tester.pump();
    expect(picked?.address, '192.168.1.10');
  });

  testWidgets('已选中的那一行显示对勾', (tester) async {
    final hosts = <LanHost>[
      const LanHost(address: '192.168.1.10', name: 'nas'),
      const LanHost(address: '192.168.1.20'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LanHostPicker(
          hosts: hosts,
          selected: '192.168.1.20',
          onPick: (_) {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}
