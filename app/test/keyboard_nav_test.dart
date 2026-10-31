import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/background.dart';
import 'package:lanplayer/data/location.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/repository.dart';
import 'package:lanplayer/ui/browser_screen.dart';
import 'package:lanplayer/ui/folder_picker.dart';
import 'package:lanplayer/ui/keyboard.dart';

/// 用户 2026-10-30 要求：按 Backspace 回到上一浏览层级。
///
/// 这组用例守住三件事：按键本身认得对、浏览页真的退了一层而不是关掉页面、
/// 退到根目录后才离开。另外顺带守住本地选择器里的同一个手势。
void main() {
  /// 造一份内核会返回的目录列表 JSON。
  ///
  /// 字段名必须与内核一致：`is_dir` 用布尔、`mtime` 是**秒**、`ext` 不带点。
  /// 写成 `kind: 'dir'` 之类会被 [MediaEntry.fromJson] 当成普通文件，
  /// 于是文件夹点不进去、整个用例都在跟空气较劲。
  String payload(String url, String parent, List<String> names) {
    final entries = [
      for (final n in names)
        {
          'name': n,
          'path': '$url/$n',
          'is_dir': !n.contains('.'),
          'kind': n.contains('.') ? 'video' : 'dir',
          'size': 1024,
          'mtime': 1730000000,
          'ext': n.contains('.') ? n.split('.').last : '',
        }
    ];
    return jsonEncode({
      'url': url,
      'parent': parent,
      'entries': entries,
    });
  }

  DirectoryListing listingOf(String url, String parent, List<String> names) =>
      DirectoryListing.fromJson(
          jsonDecode(payload(url, parent, names)) as Map<String, dynamic>);

  /// 推几帧让界面稳定下来。
  ///
  /// 这里**不能**用 `pumpAndSettle()`：列表行里的封面缩略图会去碰内核，
  /// 在测试环境里永远等不到「没有待处理帧」，直接报 pumpAndSettle timed out。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 发一次真实的按键事件：走 `HardwareKeyboard` 那条路，等价的用户操作。
  Future<void> pressBackspace(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
  }

  group('按键映射', () {
    test('Backspace 被认成返回键', () {
      expect(isBackKey(LogicalKeyboardKey.backspace), isTrue);
    });

    test('别的键不会被当成返回', () {
      for (final key in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.keyB,
      ]) {
        expect(isBackKey(key), isFalse, reason: '$key 不该触发返回');
      }
    });

    test('按下不生效，抬起才执行', () {
      final back = BackKeyHandler();
      var calls = 0;

      const key = LogicalKeyboardKey.backspace;
      const physical = PhysicalKeyboardKey.backspace;
      const when = Duration.zero;

      const down =
          KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: when);
      const up =
          KeyUpEvent(physicalKey: physical, logicalKey: key, timeStamp: when);

      expect(back.handle(down, () => calls++), KeyEventResult.handled,
          reason: '按下要被拦下，否则同一颗键会被上层再响应一次');
      expect(calls, 0, reason: '按下还没松开，不该有动作');

      expect(back.handle(up, () => calls++), KeyEventResult.handled);
      expect(calls, 1, reason: '抬起才执行一次');
    });

    test('长按期间的重复事件一律不执行', () {
      final back = BackKeyHandler();
      var calls = 0;

      const physical = PhysicalKeyboardKey.backspace;
      const when = Duration.zero;

      back.handle(
          const KeyDownEvent(
              physicalKey: physical,
              logicalKey: LogicalKeyboardKey.backspace,
              timeStamp: when),
          () => calls++);
      for (var i = 0; i < 5; i++) {
        back.handle(
            const KeyRepeatEvent(
                physicalKey: physical,
                logicalKey: LogicalKeyboardKey.backspace,
                timeStamp: when),
            () => calls++);
      }
      expect(calls, 0, reason: '按住不放不该执行任何动作');

      back.handle(
          const KeyUpEvent(
              physicalKey: physical,
              logicalKey: LogicalKeyboardKey.backspace,
              timeStamp: when),
          () => calls++);
      expect(calls, 1, reason: '长按到底也只执行一次');
    });

    test('没按过就松手不算触发（焦点是按住期间才过来的）', () {
      final back = BackKeyHandler();
      var calls = 0;

      expect(
          back.handle(
              const KeyUpEvent(
                  physicalKey: PhysicalKeyboardKey.backspace,
                  logicalKey: LogicalKeyboardKey.backspace,
                  timeStamp: Duration.zero),
              () => calls++),
          KeyEventResult.handled);
      expect(calls, 0);
    });

    test('失焦清掉按住状态，回来那次松手不再触发', () {
      final back = BackKeyHandler();
      var calls = 0;

      const physical = PhysicalKeyboardKey.backspace;
      const when = Duration.zero;
      back.handle(
          const KeyDownEvent(
              physicalKey: physical,
              logicalKey: LogicalKeyboardKey.backspace,
              timeStamp: when),
          () => calls++);
      back.reset();
      back.handle(
          const KeyUpEvent(
              physicalKey: physical,
              logicalKey: LogicalKeyboardKey.backspace,
              timeStamp: when),
          () => calls++);
      expect(calls, 0);
    });
  });

  group('浏览页按 Backspace 退一层', () {
    /// 建一个真的 BrowserScreen，取数由假实现提供。
    Widget host({
      required String rootUrl,
      required Map<String, String> tree,
      required String rootParent,
    }) {
      final repo = MediaRepository(fetchListing: (url, options) async {
        final body = tree[url];
        if (body == null) return ListingResult.failure(null);
        final parent = url == rootUrl
            ? rootParent
            : url.substring(0, url.lastIndexOf('/'));
        return ListingResult.json(payload(url, parent, body.split(',')));
      });
      final location = MediaLocation.local('本机', rootUrl);
      return MaterialApp(
        home: Builder(
          builder: (hostContext) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.of(hostContext).push(MaterialPageRoute<void>(
                  builder: (_) => BrowserScreen(
                      location: location,
                      initial: listingOf(
                          rootUrl, rootParent, tree[rootUrl]!.split(',')),
                      repo: repo),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('在子目录里按 Backspace 会退回上一层，页面还开着', (tester) async {
      const root = 'file:///media';
      final tree = {
        root: 'movies',
        '$root/movies': 'ep1.mkv,ep2.mkv',
      };

      await tester.pumpWidget(host(rootUrl: root, tree: tree, rootParent: ''));
      await tester.tap(find.text('open'));
      await settle(tester);

      // 进入 movies 子目录
      await tester.tap(find.text('movies'));
      await settle(tester);
      expect(find.text('ep1.mkv'), findsOneWidget);
      expect(find.text('movies'), findsOneWidget, reason: '标题是当前文件夹名');

      // 按 Backspace：应当回到根，而不是关掉页面
      await pressBackspace(tester);
      await settle(tester);

      expect(find.text('movies'), findsOneWidget, reason: '根目录里还有 movies');
      expect(find.text('ep1.mkv'), findsNothing, reason: '已经离开子目录');
      // 入栈路由不会把下层从树上摘掉（'open' 那个按钮还在），所以这里
      // 断言的是浏览页本身仍然在，而不是宿主页面被找回。
      expect(find.byType(BrowserScreen), findsOneWidget, reason: '浏览页本身不能被关掉');
    });

    testWidgets('已经在根目录时再按 Backspace 才离开页面', (tester) async {
      const root = 'file:///media';
      final tree = {root: 'movies'};

      await tester.pumpWidget(host(rootUrl: root, tree: tree, rootParent: ''));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('movies'), findsOneWidget);

      await pressBackspace(tester);
      await settle(tester);

      expect(find.text('open'), findsOneWidget, reason: '回到了宿主页面');
    });

    testWidgets('Backspace 之外的键不影响导航', (tester) async {
      const root = 'file:///media';
      final tree = {
        root: 'movies',
        '$root/movies': 'ep1.mkv',
      };

      await tester.pumpWidget(host(rootUrl: root, tree: tree, rootParent: ''));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.text('movies'));
      await settle(tester);
      expect(find.text('ep1.mkv'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      expect(find.text('ep1.mkv'), findsOneWidget, reason: 'Escape 不归列表页管');
    });
  });

  group('本地选择器按 Backspace 退一层', () {
    testWidgets('子目录里退一层，根层再按才关闭', (tester) async {
      const root = '/media';
      Future<DirectoryListing> lister(
          String url, Map<String, dynamic> options) async {
        final path = url.substring('file://'.length);
        if (path == root) {
          return listingOf(url, '', ['sub', 'a.mkv']);
        }
        if (path == '$root/sub') {
          return listingOf(url, 'file://$root', ['b.mkv']);
        }
        throw MediaSourceException('意外路径：$path');
      }

      LocalChoice? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (hostContext) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await pickLocalPath(
                    hostContext,
                    <({String label, String path})>[
                      (label: '本机', path: root),
                    ],
                    lister: lister,
                  );
                },
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('pick'));
      await settle(tester);

      // 进入「本机」再进 sub
      await tester.tap(find.text('本机'));
      await settle(tester);
      expect(find.text('sub'), findsOneWidget);
      await tester.tap(find.text('sub'));
      await settle(tester);
      expect(find.text('b.mkv'), findsOneWidget);

      // 退一层：回到根层的列表
      await pressBackspace(tester);
      await settle(tester);
      expect(find.text('sub'), findsOneWidget);
      expect(find.text('b.mkv'), findsNothing);

      // 再退一层：退到盘符/常用位置那一层，对话框还开着
      await pressBackspace(tester);
      await settle(tester);
      expect(find.text('本机'), findsOneWidget);
      expect(find.text('添加本地文件/文件夹'), findsOneWidget);

      // 最后一层再按：关掉对话框
      await pressBackspace(tester);
      await settle(tester);
      expect(find.text('pick'), findsOneWidget, reason: '对话框已关闭');
      expect(picked, isNull, reason: '没有选中，对话框是关掉的而不是返回了目录');
    });
  });
}
