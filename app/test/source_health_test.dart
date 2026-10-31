import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/background.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/repository.dart';
import 'package:lanplayer/data/source_health.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/home_screen.dart';

/// 「服务器不在线时点『全部』不该再等一次超时」。
///
/// 用户报的现象：那块来源上已经写着连不上了，点「全部」还要再干等十几秒才
/// 弹「出错了」—— 因为按钮每次都真的去连一遍，等到 socket 超时才失败。
///
/// 现在的口径：**启动 / 刷新 / 重试** 才去连；进目录、点「全部」这类顺着
/// 已有结论走的动作先读结论，判为离线就直接弹提示，提示里带上「请重新连接
/// 服务器或刷新后重试」。
/// 首页在「正在加载」时会转圈，`pumpAndSettle` 永远等不到静止，
/// 所以这里推固定几次让它把首帧、请求回调与重建都走完。
Future<void> settleHome(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() {
    ServerStore.instance.debugReset();
    LocalFolderStore.instance.debugReset();
    SourceHealth.instance.debugReset();
  });

  String listingJson() => jsonEncode({
        'url': '/media',
        'parent': '',
        'entries': [
          {
            'name': 'video-0.mp4',
            'path': 'file:///media/video-0.mp4',
            'kind': 'video',
            'size': 1024,
            'modified': 0,
          },
        ],
      });

  test('连失败后标记为离线，判据按来源 id 走', () {
    final health = SourceHealth.instance;
    expect(health.isOffline('dir:dir-1'), isFalse);
    health.markOffline('dir:dir-1', '无法访问 x：连接超时或服务器不可达');
    expect(health.isOffline('dir:dir-1'), isTrue);
    health.markOnline('dir:dir-1');
    expect(health.isOffline('dir:dir-1'), isFalse);
  });

  test('离线提示必须带上「请重新连接服务器或刷新后重试」', () {
    final text = offlineHint('smb://host/share', '无法访问 smb://host/share：连接超时或服务器不可达');
    expect(text, contains('请重新连接服务器或刷新后重试'));
    expect(text, contains('smb://host/share'));
    // 没给原因时也不该出现空行或 null。
    final bare = offlineHint('smb://h/s', null);
    expect(bare, contains('请重新连接服务器或刷新后重试'));
    expect(bare, isNot(contains('null')));
  });

  testWidgets('点「全部」时已知离线就直接弹提示，不再发请求', (tester) async {
    var calls = 0;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      LocalFolder(
        id: 'dir-1',
        label: '本机',
        path: '/media',
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);
    final repo = MediaRepository(
      fetchListing: (url, options) async {
        calls++;
        return ListingResult.json(listingJson());
      },
    );
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repo: repo)));
    await settleHome(tester);

    final before = calls;
    expect(before, greaterThan(0));

    // 假装上一轮连接失败过。
    SourceHealth.instance.markOffline('dir:dir-1', '无法访问 /media：连接超时或服务器不可达');

    await tester.tap(find.text('全部'));
    await settleHome(tester);

    expect(find.text('出错了'), findsOneWidget);
    expect(find.textContaining('请重新连接服务器或刷新后重试'), findsWidgets);
    expect(calls, before, reason: '已知离线时不该再发一次请求');
  });

  testWidgets('点进子目录时已知离线也直接提示', (tester) async {
    var calls = 0;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      LocalFolder(
        id: 'dir-1',
        label: '本机',
        path: '/media',
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);
    final payload = jsonEncode({
      'url': '/media',
      'parent': '/',
      'entries': [
        {
          'name': 'sub',
          'path': 'file:///media/sub',
          'kind': 'dir',
          'is_dir': true,
          'entries': 0,
          'size': 0,
          'modified': 0,
        },
      ],
    });
    final repo = MediaRepository(
      fetchListing: (url, options) async {
        calls++;
        return ListingResult.json(payload);
      },
    );
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repo: repo)));
    await settleHome(tester);

    final before = calls;
    SourceHealth.instance.markOffline('dir:dir-1', '连不上');

    await tester.tap(find.text('sub').first);
    await settleHome(tester);

    expect(find.text('出错了'), findsOneWidget);
    expect(calls, before, reason: '已知离线时不该再发一次请求');
  });

  testWidgets('重试按钮会真的再连一次，连上后清掉离线标记', (tester) async {
    var fail = true;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    LocalFolderStore.instance.debugSeed(<LocalFolder>[
      LocalFolder(
        id: 'dir-1',
        label: '本机',
        path: '/media',
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);
    final repo = MediaRepository(
      fetchListing: (url, options) async =>
          fail ? ListingResult.failure(null) : ListingResult.json(listingJson()),
    );
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repo: repo)));
    await settleHome(tester);

    expect(SourceHealth.instance.isOffline('dir:dir-1'), isTrue);

    fail = false;
    await tester.tap(find.text('重试'));
    await settleHome(tester);

    expect(SourceHealth.instance.isOffline('dir:dir-1'), isFalse,
        reason: '重试连上之后要清掉离线标记');
    expect(find.text('重试'), findsNothing);
  });
}
