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
}
