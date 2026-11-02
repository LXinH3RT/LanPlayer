import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/bindings.dart' show decodeJson;
import 'package:lanplayer/core/player_controller.dart' show PlayerController;
import 'package:lanplayer/data/stores.dart';

/// 配置文件的容错契约：坏文件既不能拖垮启动，也不能把用户数据悄悄清空。
///
/// 回归背景：`readJson` 原先在 catch 里返回 `{'_error': …}`，各 store 看到
/// 的是「没有这一项」，`_loaded` 照常置位 —— 一份半截 JSON 会让服务器列表
/// 永久变成空表，下一次保存再把空表写回磁盘，原来的内容就再也回不来了。
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('lanplayer-store-test');
    AppStorage.directoryOverride = dir;
  });

  tearDownAll(() {
    AppStorage.directoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('AppStorage.readJson', () {
    test('缺文件时返回空表，不留下任何东西', () async {
      final json = await AppStorage.readJson('absent.json');
      expect(json, isEmpty);
      expect(File('${dir.path}/absent.json').existsSync(), isFalse);
    });

    test('好的文件照常读出来', () async {
      File('${dir.path}/good.json')
          .writeAsStringSync(jsonEncode({'servers': [], 'n': 3}));
      final json = await AppStorage.readJson('good.json');
      expect(json['n'], 3);
    });

    test('坏文件先改名存档，再返回空表', () async {
      File('${dir.path}/broken.json').writeAsStringSync('{"servers": [');
      final json = await AppStorage.readJson('broken.json');
      expect(json, isEmpty);
      // 原文件不能还在原处：留着它，下一次 writeJson 就会把能抢救的内容覆盖掉。
      expect(File('${dir.path}/broken.json').existsSync(), isFalse);
      final kept = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('broken.json.corrupt-'))
          .toList();
      expect(kept, hasLength(1), reason: '损坏的原文件应该改名留证');
      expect(kept.first.readAsStringSync(), '{"servers": [');
    });

    test('空白文件当没有配置，不算损坏', () async {
      File('${dir.path}/blank.json').writeAsStringSync('   ');
      expect(await AppStorage.readJson('blank.json'), isEmpty);
      expect(File('${dir.path}/blank.json').existsSync(), isTrue);
    });
  });

  group('decodeJson', () {
    test('畸形 payload 返回 null，不抛异常', () {
      // 事件是从 FFI 回调里同步送进来的：抛 FormatException 会穿过
      // NativeCallable 一路把播放流程带停。
      expect(decodeJson('{"a":1}'), {'a': 1});
      expect(decodeJson('{"a":'), isNull);
      expect(decodeJson(''), isNull);
      expect(decodeJson('[1,2]'), isNull);
      expect(decodeJson('null'), isNull);
    });
  });

  group('PlayerController.clampPosition', () {
    test('时长已知时夹在区间内', () {
      expect(PlayerController.clampPosition(-500, 1000), 0);
      expect(PlayerController.clampPosition(400, 1000), 400);
      expect(PlayerController.clampPosition(9999, 1000), 1000);
    });

    test('时长未知时不会因为下界大于上界而抛异常', () {
      // 回归背景：旧写法是 micros.clamp(0, durationUs == 0 ? micros : durationUs)，
      // durationUs 为 0 且 micros 为负时 clamp(0, -500) 直接抛 ArgumentError。
      expect(PlayerController.clampPosition(-500, 0), 0);
      expect(PlayerController.clampPosition(0, 0), 0);
      expect(PlayerController.clampPosition(700, 0), 700);
    });
  });
}
