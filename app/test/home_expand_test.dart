import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/background.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/repository.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/home_screen.dart';

/// 「还有 N 项」要就地摊开，不再跳到次级界面。
///
/// 回归背景：首页一块来源最多直接列 8 行，多出来的部分显示成「还有 N 项」。
/// 那个按钮以前 push 一个浏览页 —— 用户点下去以为能看到更多，结果只是把
/// 同一份列表换个界面又列一遍，还得退回来。现在改成把剩下的行接在下面，
/// 再点一次「收起」恢复。
void main() {
  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
  });

  /// 假的内核返回：[folders] 个文件夹 + [videos] 个视频。
  String listingJson({int folders = 0, int videos = 0}) {
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < folders; i++)
        {
          'name': 'dir-$i',
          'path': 'file:///media/dir-$i',
          'kind': 'dir',
          'size': 0,
          'modified': 0,
        },
      for (var i = 0; i < videos; i++)
        {
          'name': 'video-$i.mp4',
          'path': 'file:///media/video-$i.mp4',
          'kind': 'video',
          'size': 1024,
          'modified': 0,
        },
    ];
    return jsonEncode({
      'url': '/media',
      'parent': '',
      'entries': entries,
    });
  }

  Future<void> pumpHome(WidgetTester tester, String payload) async {
    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      LocalFolder(
        id: 'dir-1',
        label: '本机',
        path: '/media',
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);
    final repo = MediaRepository(
      fetchListing: (url, options) async => ListingResult.json(payload),
    );
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repo: repo)));
    // 不用 pumpAndSettle：封面缩略图在测试里会去碰内核，帧永远settle不下来。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('12 项只在首页列 8 行，余下收在「还有 4 项」', (tester) async {
    await pumpHome(tester, listingJson(videos: 12));

    expect(find.text('video-7.mp4'), findsOneWidget);
    expect(find.text('video-8.mp4'), findsNothing);
    expect(find.text('还有 4 项'), findsOneWidget);
  });

  testWidgets('点「还有 4 项」把剩下的接在下面，不推进新页面', (tester) async {
    await pumpHome(tester, listingJson(videos: 12));
    final before = tester.state<NavigatorState>(find.byType(Navigator));

    // 8 行列表加标题已经超出一屏，按钮要先滚进视口才点得到。
    await tester.ensureVisible(find.text('还有 4 项'));
    await tester.pump();
    await tester.tap(find.text('还有 4 项'));
    await tester.pump();
    // 先确认展开动作生效（按钮换成「收起」），再滚到新增的行。
    expect(find.text('收起'), findsOneWidget,
        reason: '点了「还有 4 项」就该变成本地展开');
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    // 就地展开：剩下四行出现在首页上。
    expect(find.text('video-8.mp4'), findsOneWidget);
    expect(find.text('video-11.mp4'), findsOneWidget);
    // 没有新页面：还能找到首页标题，且按钮变成「收起」。
    expect(find.text('LanPlayer'), findsOneWidget);
    expect(find.text('还有 4 项'), findsNothing);
    expect(find.text('收起'), findsOneWidget);
    // 导航栈没变 —— 这是需求的核心：不新进入一个次级界面。
    expect(tester.state<NavigatorState>(find.byType(Navigator)), same(before));
  });

  testWidgets('展开后再点「收起」回到 8 行', (tester) async {
    await pumpHome(tester, listingJson(videos: 12));

    await tester.ensureVisible(find.text('还有 4 项'));
    await tester.pump();
    await tester.tap(find.text('还有 4 项'));
    await tester.pump();
    await tester.ensureVisible(find.text('收起'));
    await tester.pump();
    await tester.tap(find.text('收起'));
    await tester.pump();

    expect(find.text('video-8.mp4'), findsNothing);
    expect(find.text('还有 4 项'), findsOneWidget);
  });

  testWidgets('不超过 8 行时不出现任何展开按钮', (tester) async {
    await pumpHome(tester, listingJson(folders: 2, videos: 3));

    expect(find.text('还有 3 项'), findsNothing);
    expect(find.text('收起'), findsNothing);
    expect(find.text('video-2.mp4'), findsOneWidget);
  });
}
