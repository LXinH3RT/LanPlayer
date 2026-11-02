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
      volumeGain: 0.4,
      autoNext: false,
      subtitleScale: 1.5,
      subtitleDelayMs: -300,
      rememberProgress: false,
      themeMode: AppThemeMode.light,
    );
    final back = PlaybackSettings.fromJson(s.toJson());
    expect(back.hardwareDecoding, isFalse);
    expect(back.deinterlace, isTrue);
    expect(back.scaleMode, 2);
    expect(back.speed, 1.5);
    expect(back.volumeGain, 0.4);
    expect(back.autoNext, isFalse);
    expect(back.subtitleScale, 1.5);
    expect(back.subtitleDelayMs, -300);
    expect(back.rememberProgress, isFalse);
    expect(back.themeMode, AppThemeMode.light);
  });

  test('外观主题默认是黑色，老配置里没有该字段也回到黑色', () {
    expect(PlaybackSettings().themeMode, AppThemeMode.dark);
    expect(AppThemeMode.defaultMode, AppThemeMode.dark);
    final old = PlaybackSettings.fromJson(<String, dynamic>{'speed': 1.0});
    expect(old.themeMode, AppThemeMode.dark);
    // 认不出来的值（比如手改错了）同样退回黑色，不是白屏。
    final bad =
        PlaybackSettings.fromJson(<String, dynamic>{'theme_mode': 'neon'});
    expect(bad.themeMode, AppThemeMode.dark);
  });

  test('字幕大小与延迟吸附到下拉框里真实存在的档位', () {
    // 老配置里是滑杆的连续值，改下拉之后必须贴到最近的档，否则
    // DropdownButton 拿到的 value 不在 items 里会直接抛断言。
    final s = PlaybackSettings.fromJson(<String, dynamic>{
      'subtitle_scale': 1.4,
      'subtitle_delay_ms': -350,
    });
    expect(
        PlaybackSettings.subtitleScaleSteps.contains(s.subtitleScale), isTrue);
    expect(PlaybackSettings.subtitleDelaySteps.contains(s.subtitleDelayMs),
        isTrue);
    // 1.4 正好在 1.3 与 1.5 中间，吸附取先遇到的那一档（1.3），
    // 关键是结果一定落在档位表里，下拉框才选得中。
    expect(s.subtitleScale, 1.3);
    expect(s.subtitleDelayMs, -300);
    // 缺字段与类型不对时回到 1.0 / 0。
    expect(PlaybackSettings.clampSubtitleScale(null), 1.0);
    expect(PlaybackSettings.clampSubtitleScale('big'), 1.0);
    expect(PlaybackSettings.clampSubtitleDelay(null), 0);
    expect(PlaybackSettings.clampSubtitleDelay('late'), 0);
  });
}
