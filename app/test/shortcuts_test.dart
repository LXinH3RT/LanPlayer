import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';

void main() {
  group('快捷键目录', () {
    test('每个动作的 id 唯一，且能反查回来', () {
      final ids = <String>{};
      for (final a in ShortcutAction.values) {
        expect(ids.add(a.id), isTrue, reason: '${a.id} 重复了');
        expect(ShortcutAction.byId(a.id), same(a));
      }
    });

    test('出厂绑定时没有两个动作抢同一个键', () {
      final seen = <LogicalKeyboardKey, ShortcutAction>{};
      for (final a in ShortcutAction.values) {
        final key = ShortcutBindings.empty.keyFor(a);
        if (key == null) continue;
        expect(seen.containsKey(key), isFalse,
            reason: '${a.id} 与 ${seen[key]?.id} 都占着 ${ShortcutBindings.label(key)}');
        seen[key] = a;
      }
    });

    test('播放 / 暂停默认是空格，快进快退默认是左右方向键', () {
      const b = ShortcutBindings.empty;
      expect(b.keyFor(ShortcutAction.playPause), LogicalKeyboardKey.space);
      expect(b.keyFor(ShortcutAction.seekBack), LogicalKeyboardKey.arrowLeft);
      expect(b.keyFor(ShortcutAction.seekForward), LogicalKeyboardKey.arrowRight);
    });

    test('倍速三个动作出厂不绑键（键位留给用户）', () {
      const b = ShortcutBindings.empty;
      expect(b.keyFor(ShortcutAction.speedUp), isNull);
      expect(b.keyFor(ShortcutAction.speedDown), isNull);
      expect(b.keyFor(ShortcutAction.speedReset), isNull);
    });

    test('键的显示名：空格 / 方向键 / 字母都有可读写法', () {
      expect(ShortcutBindings.label(LogicalKeyboardKey.space), '空格');
      expect(ShortcutBindings.label(LogicalKeyboardKey.arrowLeft), '←');
      expect(ShortcutBindings.label(LogicalKeyboardKey.keyF), 'F');
      expect(ShortcutBindings.label(LogicalKeyboardKey.backspace), '退格');
    });
  });

  group('改键', () {
    test('绑定一个键后 keyFor 立刻返回它', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.playPause, LogicalKeyboardKey.keyP);
      expect(b.keyFor(ShortcutAction.playPause), LogicalKeyboardKey.keyP);
    });

    test('抢占别人的键时，原主人被解绑（不是两个动作共用一个键）', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.seekBack, LogicalKeyboardKey.keyS);
      // keyS 原本属于「解码统计」。
      expect(b.keyFor(ShortcutAction.seekBack), LogicalKeyboardKey.keyS);
      expect(b.keyFor(ShortcutAction.stats), isNull);
    });

    test('conflictFor 能提前问出会抢走谁', () {
      final hit = ShortcutBindings.empty
          .conflictFor(ShortcutAction.seekBack, LogicalKeyboardKey.keyS);
      expect(hit, ShortcutAction.stats);
      final none = ShortcutBindings.empty
          .conflictFor(ShortcutAction.seekBack, LogicalKeyboardKey.keyP);
      expect(none, isNull);
    });

    test('解绑（传 null）与「没配置」是两回事', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.playPause, null);
      expect(b.keyFor(ShortcutAction.playPause), isNull);
      expect(b.isDefault, isFalse);
      expect(b.toJson(), {'play_pause': null});
    });

    test('单独重置一个动作会回到出厂键', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.playPause, LogicalKeyboardKey.keyP);
      final r = b.resetOne(ShortcutAction.playPause);
      expect(r.keyFor(ShortcutAction.playPause), LogicalKeyboardKey.space);
      expect(r.isDefault, isTrue);
    });

    test('全部重置后回到空表', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.playPause, LogicalKeyboardKey.keyP)
          .bind(ShortcutAction.mute, LogicalKeyboardKey.keyN);
      expect(b.resetAll().isDefault, isTrue);
    });
  });

  group('序列化', () {
    test('只存改过的项，没改过的不写进去', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.mute, LogicalKeyboardKey.keyN);
      expect(b.toJson(), {'mute': LogicalKeyboardKey.keyN.keyId});
    });

    test('存进去再读回来，键和动作都对得上', () {
      final b = ShortcutBindings.empty
          .bind(ShortcutAction.playPause, LogicalKeyboardKey.keyP)
          .bind(ShortcutAction.speedUp, LogicalKeyboardKey.bracketRight);
      final back = ShortcutBindings.fromJson(b.toJson());
      expect(back.keyFor(ShortcutAction.playPause), LogicalKeyboardKey.keyP);
      expect(back.keyFor(ShortcutAction.speedUp),
          LogicalKeyboardKey.bracketRight);
    });

    test('解绑能存能读', () {
      final b = ShortcutBindings.empty.bind(ShortcutAction.mute, null);
      final back = ShortcutBindings.fromJson(b.toJson());
      expect(back.keyFor(ShortcutAction.mute), isNull);
    });

    test('老版本留下的未知动作名直接忽略，不会把整份配置读坏', () {
      final back = ShortcutBindings.fromJson({
        'gone_action': 32,
        'mute': LogicalKeyboardKey.keyN.keyId,
      });
      expect(back.isDefault, isFalse);
      expect(back.keyFor(ShortcutAction.mute), LogicalKeyboardKey.keyN);
    });

    test('settings.json 里没有 shortcuts 字段时用的是出厂表', () {
      final s = PlaybackSettings.fromJson({'version': 1});
      expect(s.shortcuts.isDefault, isTrue);
      expect(s.shortcuts.keyFor(ShortcutAction.playPause),
          LogicalKeyboardKey.space);
    });

    test('PlaybackSettings 往返后绑定还在', () {
      final s = PlaybackSettings()
        ..shortcuts =
            ShortcutBindings.empty.bind(ShortcutAction.mute, LogicalKeyboardKey.keyN);
      final back = PlaybackSettings.fromJson(s.toJson());
      expect(back.shortcuts.keyFor(ShortcutAction.mute), LogicalKeyboardKey.keyN);
    });

    test('没改过时不往 settings.json 里塞空对象', () {
      final json = PlaybackSettings().toJson();
      expect(json.containsKey('shortcuts'), isFalse);
    });
  });

  group('鼠标手势说明', () {
    test('鼠标手势全部列出，且每条都有说明文字', () {
      expect(PointerGesture.all.length, greaterThanOrEqualTo(8));
      for (final g in PointerGesture.all) {
        expect(g.gesture.trim(), isNotEmpty);
        expect(g.effect.trim(), isNotEmpty);
      }
    });

    test('双击左右三分之一与长按倍速都在列表里', () {
      final all = PointerGesture.all.map((g) => g.gesture).join('|');
      expect(all.contains('双击画面左侧三分之一'), isTrue);
      expect(all.contains('双击画面右侧三分之一'), isTrue);
      expect(all.contains('长按画面'), isTrue);
      expect(all.contains('滚轮'), isTrue);
    });
  });
}
