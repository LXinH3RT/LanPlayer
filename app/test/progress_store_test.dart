import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/progress.dart';
import 'package:lanplayer/data/stores.dart';

/// 进度表的两个契约：
///
///  * 冷启动窗口里先写后读时，**不能**用空表把磁盘上已有的进度覆盖掉；
///  * 读完写出来的 JSON 仍然能被下一份实例原样读回。
///
/// 回归背景：`main.dart` 里 `ProgressStore.instance.load()` 只是
/// `Future.wait` 的一项，`runApp` 早就跑起来了。播放页在同一个帧里就可能
/// 调 `save()`，而 `_flush()` 原先没有 `_loaded` 守卫，落盘的是「只有刚刚
/// 这一条」的快照 —— 磁盘上几百条进度整个没了。
void main() {
  late Directory dir;

  // AppStorage 会缓存解析出来的目录（`_dir`），所以整个文件共用一个临时
  // 目录，每个用例自己删掉 progress.json。每次新建目录会让缓存指向一个
  // 已经被删掉的路径。
  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('lanplayer-progress-test');
    AppStorage.directoryOverride = dir;
  });

  setUp(() {
    final f = File('${dir.path}/progress.json');
    if (f.existsSync()) f.deleteSync();
  });

  tearDownAll(() {
    AppStorage.directoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File progressFile() => File('${dir.path}/progress.json');

  void seedDisk(List<Map<String, dynamic>> entries) {
    progressFile().writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': entries,
    }));
  }

  List<Map<String, dynamic>> entriesOnDisk() {
    final raw =
        jsonDecode(progressFile().readAsStringSync()) as Map<String, dynamic>;
    return (raw['entries'] as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> entry(String key, int posUs, int durUs) => {
        'key': key,
        'position_us': posUs,
        'duration_us': durUs,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

  test('没读过盘就保存时，先把盘上的内容读进来再写', () async {
    seedDisk([
      entry('file:///a.mkv', 60000000, 3600000000),
      entry('file:///b.mkv', 120000000, 3600000000),
    ]);

    final store = ProgressStore.forTest();
    await store.save('file:///c.mkv', 30000000, 3600000000);
    // save 之后落盘是合并延迟的（250 ms 内多次只写一次），测试要立刻看到结果。
    await store.flushNow();

    // 三条都在：新的一条加上磁盘上原有的两条。
    expect(progressFile().existsSync(), isTrue);
    final keys = entriesOnDisk().map((e) => e['key']).toList();
    expect(keys, containsAll(<String>['file:///a.mkv', 'file:///b.mkv']));
    expect(keys.where((k) => k == 'file:///c.mkv'), hasLength(1));
  });

  test('先 load 再 save 的结果能原样读回', () async {
    seedDisk([entry('file:///a.mkv', 60000000, 3600000000)]);

    final writer = ProgressStore.forTest();
    await writer.load();
    await writer.save('file:///d.mkv', 90000000, 3600000000);
    await writer.flushNow();

    final reader = ProgressStore.forTest();
    await reader.load();
    expect(reader.entry('file:///a.mkv')?.positionUs, 60000000);
    expect(reader.entry('file:///d.mkv')?.positionUs, 90000000);
  });

  test('接近片尾的位置会被忘掉，其它条目不受影响', () async {
    seedDisk([
      entry('file:///a.mkv', 60000000, 3600000000),
      entry('file:///b.mkv', 3599000000, 3600000000),
    ]);

    final store = ProgressStore.forTest();
    await store.save('file:///b.mkv', 3599000000, 3600000000);

    final keys = entriesOnDisk().map((e) => e['key']).toList();
    expect(keys, contains('file:///a.mkv'));
    expect(keys, isNot(contains('file:///b.mkv')));
  });

  test('sanitizeKey 剥掉 userinfo，但不动路径里的转义', () {
    // 带凭据的 SMB 地址进进度表时，账号密码必须被抹掉 —— 这是唯一挡住
    // 「密码被写进 progress.json」的地方。
    expect(
      ProgressStore.sanitizeKey('smb://user:pass@192.168.1.7/share/a.mkv'),
      'smb://192.168.1.7/share/a.mkv',
    );
    // 路径里的 %2F 是文件名的一部分，不能被再解一次码。
    expect(
      ProgressStore.sanitizeKey('smb://192.168.1.7/share/a%2Fb.mkv'),
      'smb://192.168.1.7/share/a%2Fb.mkv',
    );
    // 其它转义要还原，否则「列表给的原始 UTF-8」与「播放时的转义 URL」
    // 会变成两条记录。
    expect(
      ProgressStore.sanitizeKey('smb://192.168.1.7/share/%E7%94%B5%E5%BD%B1.mkv'),
      'smb://192.168.1.7/share/电影.mkv',
    );
    // 盘符的两种写法归一成同一个 key，否则同一个文件会有两条进度。
    expect(
      ProgressStore.sanitizeKey('file:///D:/video/a.mkv'),
      ProgressStore.sanitizeKey('file://D:/video/a.mkv'),
    );
    // 没有凭据的地址除归一化外不动。
    expect(
      ProgressStore.sanitizeKey('smb://192.168.1.7/share/a.mkv'),
      'smb://192.168.1.7/share/a.mkv',
    );
  });

  test('超过 maxEntries 时按 updatedAt 截掉最旧的', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    seedDisk([
      for (var i = 0; i < ProgressStore.maxEntries + 5; i++)
        {
          'key': 'file:///v$i.mkv',
          'position_us': 60000000,
          'duration_us': 3600000000,
          // i 越大越新：截断应该优先丢掉 i 小的那些。
          'updated_at': now - (ProgressStore.maxEntries + 5 - i) * 1000,
        },
    ]);

    final store = ProgressStore.forTest();
    await store.load();
    await store.save('file:///newest.mkv', 60000000, 3600000000);
    await store.flushNow();

    final keys = entriesOnDisk().map((e) => e['key']).toList();
    expect(keys.length, lessThanOrEqualTo(ProgressStore.maxEntries));
    expect(keys, contains('file:///newest.mkv'));
    // 最旧的那几条被丢掉了，较新的还在。
    expect(keys, isNot(contains('file:///v0.mkv')));
    expect(keys, contains('file:///v${ProgressStore.maxEntries + 4}.mkv'));
  });

  test('250 ms 内的连续 save 只落盘一次', () async {
    final store = ProgressStore.forTest();
    await store.load();

    for (var i = 0; i < 5; i++) {
      await store.save('file:///burst$i.mkv', 60000000, 3600000000);
    }
    // 合并窗口里还没落盘：磁盘上应该一条都没有。
    final before = progressFile().existsSync()
        ? entriesOnDisk().map((e) => e['key'] as String).toList()
        : const <String>[];
    expect(before.where((k) => k.startsWith('file:///burst')), isEmpty);

    await store.flushNow();
    final after = entriesOnDisk().map((e) => e['key'] as String).toList();
    expect(after.where((k) => k.startsWith('file:///burst')), hasLength(5));
  });
}
