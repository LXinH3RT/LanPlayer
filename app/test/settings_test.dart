import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';

/// 「记忆上次播放位置」开关的持久化契约。
///
/// 这个开关决定播放器是否读写 `progress.json`，一旦默认值搞错，
/// 用户升级后会突然丢掉所有续播位置（或者突然多出一堆不该有的记录），
/// 所以默认值与老配置的兼容性单独用测试锁住。
void main() {
  test('记忆播放位置默认开启', () {
    expect(PlaybackSettings().rememberProgress, isTrue);
  });

  test('老配置文件没有该字段时仍按开启处理', () {
    // 升级前写出的 settings.json 里不会有 remember_progress。
    final old = PlaybackSettings.fromJson(<String, dynamic>{
      'hardware_decoding': false,
      'speed': 1.25,
    });
    expect(old.rememberProgress, isTrue);
    expect(old.hardwareDecoding, isFalse);
    expect(old.speed, 1.25);
  });

  test('关闭后能写入 JSON 并原样读回', () {
    final off = PlaybackSettings()..rememberProgress = false;
    final json = off.toJson();
    expect(json['remember_progress'], isFalse);
    expect(PlaybackSettings.fromJson(json).rememberProgress, isFalse);
  });

  test('toJson 每个字段都能往返', () {
    final s = PlaybackSettings(
      hardwareDecoding: false,
      deinterlace: true,
      scaleMode: 2,
      speed: 1.5,
      volume: 0.4,
      autoNext: false,
      subtitleScale: 1.4,
      subtitleDelayMs: -350,
      rememberProgress: false,
    );
    final back = PlaybackSettings.fromJson(s.toJson());
    expect(back.hardwareDecoding, isFalse);
    expect(back.deinterlace, isTrue);
    expect(back.scaleMode, 2);
    expect(back.speed, 1.5);
    expect(back.volume, 0.4);
    expect(back.autoNext, isFalse);
    expect(back.subtitleScale, 1.4);
    expect(back.subtitleDelayMs, -350);
    expect(back.rememberProgress, isFalse);
  });
}
