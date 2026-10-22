import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';

/// 默认音轨 / 字幕轨的选择逻辑。
///
/// 用户报的现象：多音轨的片子默认播了英文轨。根因是内核用
/// `av_find_best_stream`，只看「第一条」不看语言。修法是让用户在设置里
/// 指定首选/次选语言，播放器拿到轨道信息后按偏好重选一次。
///
/// 这里锁住选择顺序：首选语言 → 次选语言 → 容器默认标记 → 第一条。
void main() {
  TrackChoice t(int index,
          {String lang = '',
          String title = '',
          bool def = false,
          bool ext = false}) =>
      TrackChoice(
          index: index,
          lang: lang,
          title: title,
          isDefault: def,
          external: ext);

  group('语言归一化', () {
    test('二字母 / 三字母 / 带地区都指向同一种语言', () {
      for (final s in [
        'zh',
        'zh-CN',
        'zh_Hans',
        'chi',
        'zho',
        '中文',
        '普通话',
        'chs'
      ]) {
        expect(normalizeLanguage(s), 'chi', reason: s);
      }
      for (final s in ['en', 'eng', 'English', '英文']) {
        expect(normalizeLanguage(s), 'eng', reason: s);
      }
    });

    test('认不出的原样返回小写，空串仍是空串', () {
      expect(normalizeLanguage(''), '');
      expect(normalizeLanguage('xx-YY'), 'xx');
    });

    test('sameLanguage 不把 zh 和 en 判成一样', () {
      expect(sameLanguage('zh', 'chi'), isTrue);
      expect(sameLanguage('zh', 'en'), isFalse);
      expect(sameLanguage('', 'zh'), isFalse);
    });
  });

  group('音轨选择顺序', () {
    final tracks = [
      t(1, lang: 'eng', title: 'English 5.1'),
      t(2, lang: 'chi', title: '国语'),
      t(3, lang: 'jpn', title: '日本語'),
    ];

    test('首选中文时选中文，而不是第一条英文（用户报的问题）', () {
      final idx = pickTrack(tracks, const TrackPreference(primary: 'zh'));
      expect(idx, 2, reason: '必须跳过第一条的 eng');
    });

    test('首选日语时选日语', () {
      expect(pickTrack(tracks, const TrackPreference(primary: 'ja')), 3);
    });

    test('首选不存在时用次选', () {
      final idx = pickTrack(
          tracks, const TrackPreference(primary: 'fr', secondary: 'en'));
      expect(idx, 1, reason: 'fr 没有，次选 en 命中第一条');
    });

    test('首选次选都没有时用容器默认标记', () {
      final list = [
        t(1, lang: 'fre'),
        t(2, lang: 'ger', def: true),
        t(3, lang: 'spa'),
      ];
      expect(
        pickTrack(list, const TrackPreference(primary: 'zh', secondary: 'ja')),
        2,
      );
    });

    test('什么都没标注时退回第一条', () {
      final list = [t(5), t(7), t(9)];
      expect(pickTrack(list, const TrackPreference()), 5);
    });

    test('auto 不改变「跟随文件默认」的语义', () {
      final list = [t(1), t(2, def: true)];
      // auto + auto：走默认标记
      expect(pickTrack(list, const TrackPreference()), 2);
    });

    test('语言标签缺失时用标题兜底', () {
      final list = [
        t(1, title: 'English'),
        t(2, title: '国语'),
      ];
      expect(pickTrack(list, const TrackPreference(primary: 'zh')), 2);
    });

    test('没有轨道时返回 null', () {
      expect(pickTrack(const [], const TrackPreference(primary: 'zh')), isNull);
    });
  });

  group('字幕选择', () {
    test('内嵌优先于外挂（外挂只是补充，不该抢默认）', () {
      final list = [
        t(0, lang: 'chi', ext: true),
        t(1, lang: 'chi'),
      ];
      // 两条都命中中文，内嵌那条应当被选
      expect(pickTrack(list, const TrackPreference(primary: 'zh')), 1);
    });

    test('简体/繁体都算中文', () {
      final list = [
        t(1, lang: 'chi', title: '简体'),
        t(2, lang: 'chi', title: '繁体')
      ];
      expect(pickTrack(list, const TrackPreference(primary: 'zh')), isNotNull);
    });
  });

  group('设置项持久化', () {
    test('默认值：音频和字幕都偏中文', () {
      final s = PlaybackSettings();
      // 音频不能默认 auto —— 那等于把「默认播英文轨」的 bug 留着让用户
      // 自己去设置里改，而用户报的就是这个。
      expect(s.audioPreference.primary, 'zh');
      expect(s.subtitlePreference.primary, 'zh');
    });

    test('存盘再读回来保持一致', () {
      final s = PlaybackSettings()
        ..audioPreference =
            const TrackPreference(primary: 'zh', secondary: 'en')
        ..subtitlePreference =
            const TrackPreference(primary: 'ja', secondary: 'zh');
      final back = PlaybackSettings.fromJson(s.toJson());
      expect(back.audioPreference.primary, 'zh');
      expect(back.audioPreference.secondary, 'en');
      expect(back.subtitlePreference.primary, 'ja');
      expect(back.subtitlePreference.secondary, 'zh');
    });

    test('老配置（没有新字段）不会崩，落回默认', () {
      final back = PlaybackSettings.fromJson({'volume': 0.8});
      expect(back.volume, 0.8);
      expect(back.audioPreference.primary, 'zh');
      expect(back.subtitlePreference.primary, 'zh');
    });

    test('copy() 会带上偏好（播放页用的是 copy）', () {
      final s = PlaybackSettings()
        ..audioPreference = const TrackPreference(primary: 'ja');
      expect(s.copy().audioPreference.primary, 'ja');
    });
  });

  group('语言选项表', () {
    test('包含 auto 且是第一个', () {
      expect(kLanguageOptions.first.code, 'auto');
      expect(kLanguageOptions.length, greaterThan(5));
    });

    test('每个 code 唯一', () {
      final codes = kLanguageOptions.map((e) => e.code).toSet();
      expect(codes.length, kLanguageOptions.length);
    });
  });
}
