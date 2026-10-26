import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/folder_picker.dart';

/// 选择器往回走的那两条路：同一层的「上一级」按钮，和一路退回盘符列表。
///
/// 这里锁的是一个真实报障：进子目录再返回，上级目录里的文件全都不见了。
/// 原因是 `_listing` 只对应当前这一层，弹栈之后没人去拉上一层，界面就把
/// 「没有数据」画成了「这一层是空的」。
DirectoryListing _listing(String url, List<MediaEntry> entries) =>
    DirectoryListing(url: url, parent: '', entries: entries);

MediaEntry _dir(String path, String name) => MediaEntry(
      name: name,
      path: path,
      isDir: true,
      size: 0,
      kind: 'dir',
      ext: '',
    );

MediaEntry _video(String path, String name) => MediaEntry(
      name: name,
      path: path,
      isDir: false,
      size: 1024,
      kind: 'video',
      ext: 'mp4',
    );

void main() {
  testWidgets('返回上一级后，上级目录里的文件仍然显示', (tester) async {
    final calls = <String>[];
    Future<DirectoryListing> fake(
        String url, Map<String, dynamic> options) async {
      calls.add(url);
      if (url.endsWith('/sub')) {
        return _listing(url, [_video('$url/inside.mp4', 'inside.mp4')]);
      }
      return _listing(url, [
        _dir('$url/sub', 'sub'),
        _video('$url/top.mp4', 'top.mp4'),
      ]);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickLocalPath(
              context,
              const [(label: 'D 盘', path: r'D:\media')],
              lister: fake,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 盘符 → 根目录
    await tester.tap(find.text('D 盘'));
    await tester.pumpAndSettle();
    expect(find.text('top.mp4'), findsOneWidget);
    expect(find.text('sub'), findsOneWidget);

    // 进子目录
    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();
    expect(find.text('inside.mp4'), findsOneWidget);
    expect(find.text('top.mp4'), findsNothing);

    // 上一级：上级的文件必须回来，而不是「这一层是空的」
    await tester.tap(find.byTooltip('上一级'));
    await tester.pumpAndSettle();
    expect(find.text('这一层是空的，可以直接选它'), findsNothing);
    expect(find.text('top.mp4'), findsOneWidget);
    expect(find.text('sub'), findsOneWidget);
    expect(calls.where((u) => u.endsWith('media')).length, 2,
        reason: '返回时应当重新列一次上级目录');
  });

  testWidgets('一路退回盘符列表时不发请求', (tester) async {
    final calls = <String>[];
    Future<DirectoryListing> fake(
        String url, Map<String, dynamic> options) async {
      calls.add(url);
      return _listing(url, [_video('$url/a.mp4', 'a.mp4')]);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickLocalPath(
              context,
              const [(label: 'D 盘', path: r'D:\media')],
              lister: fake,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D 盘'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));

    await tester.tap(find.byTooltip('上一级'));
    await tester.pumpAndSettle();
    // 回到盘符层：标题变回对话框标题，盘符行重新出现。
    expect(find.text('添加本地文件/文件夹'), findsOneWidget);
    expect(find.text('D 盘'), findsOneWidget);
    expect(calls, hasLength(1), reason: '盘符层是本地常量列表，不该再请求');
  });

  testWidgets('返回到中间层级时，上一级的文件列表重新拉一遍', (tester) async {
    final calls = <String>[];
    Future<DirectoryListing> fake(
        String url, Map<String, dynamic> options) async {
      calls.add(url);
      if (url.endsWith('/b')) {
        return _listing(url, [_video('$url/deep.mp4', 'deep.mp4')]);
      }
      if (url.endsWith('/a')) {
        return _listing(url, [
          _dir('$url/b', 'b'),
          _video('$url/mid.mp4', 'mid.mp4'),
        ]);
      }
      return _listing(url, [_dir('$url/a', 'a')]);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickLocalPath(
              context,
              const [(label: 'D 盘', path: r'D:\media')],
              lister: fake,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D 盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    expect(find.text('mid.mp4'), findsOneWidget);

    await tester.tap(find.text('b'));
    await tester.pumpAndSettle();
    expect(find.text('deep.mp4'), findsOneWidget);

    await tester.tap(find.byTooltip('上一级'));
    await tester.pumpAndSettle();
    expect(find.text('这一层是空的，可以直接选它'), findsNothing);
    expect(find.text('mid.mp4'), findsOneWidget);
  });
}
