import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/subtitle_match.dart';

/// 这里的文件名全部取自真实片库（SMB 共享里那些配不上的字幕），
/// 是这套近似匹配唯一需要覆盖的输入。
void main() {
  bool matches(String video, String sub) => subtitleBelongsTo(video, sub);

  group('主干直接对上', () {
    test('同名', () {
      expect(matches('电影.mkv', '电影.srt'), isTrue);
    });

    test('带语言后缀', () {
      expect(matches('movie.mkv', 'movie.zh-CN.srt'), isTrue);
      expect(matches('movie.mkv', 'movie.eng.ass'), isTrue);
    });

    test('分隔符认点、下划线、连字符、空格', () {
      for (final sep in ['.', '_', '-', ' ']) {
        expect(matches('movie.mkv', 'movie${sep}zh.srt'), isTrue,
            reason: '分隔符 $sep');
      }
    });

    test('大小写不敏感', () {
      expect(matches('Movie.MKV', 'movie.zh.SRT'), isTrue);
    });
  });

  group('续集不能错配', () {
    test('movie2.srt 不属于 movie.mkv', () {
      expect(matches('movie.mkv', 'movie2.srt'), isFalse);
    });

    test('悠哉日常大王013 不属于 001', () {
      expect(matches('悠哉日常大王001.mkv', '悠哉日常大王013.ass'), isFalse);
    });

    test('异集：S01E02 的字幕不能挂到 S01E01', () {
      expect(matches('Show.S01E01.mkv', 'Show.S01E02.zh.srt'), isFalse);
    });
  });

  group('跨语言片名不强凑', () {
    test('兵临城下 不会配上 Enemy at the Gates', () {
      expect(
        matches('兵临城下.mp4',
            'Enemy.At.The.Gates.2001.1080p.BrRip.x264.YIFY.srt'),
        isFalse,
      );
    });

    test('终结者1 不会配上 The Terminator', () {
      expect(
        matches('终结者1.mp4',
            'The.Terminator.1984.1080p.BRrip.x264.GAZ.YIFY.srt'),
        isFalse,
      );
    });

    test('警察故事1988 不会配上 Police Story 2', () {
      expect(
        matches('警察故事1988.mp4',
            'Police Story 2 (1988) 1080p BluRay H264 DolbyD 5.1 + nickarad.eng.srt'),
        isFalse,
      );
    });
  });

  group('发布组标签与语言标签', () {
    test('寒蝉鸣泣之时·解：只多了语言标签', () {
      const video =
          '[YYDM-11FANS][Higurashi no Naku Koro ni Kai][01][BDRIP][720P][X264-10bit_AAC][D12B2CA8].mp4';
      const sub =
          '[YYDM-11FANS][Higurashi no Naku Koro ni Kai][01][BDRIP][720P][X264-10bit_AAC][D12B2CA8].SC-CASO&I.G.ass';
      expect(matches(video, sub), isTrue);
    });

    test('勇敢的心：字幕多了语言标签 en', () {
      expect(matches('勇敢的心.mp4', '勇敢的心en.srt'), isTrue);
    });

    test('微软雅黑这类字体标签不算片名的一部分', () {
      expect(
        matches("S11E01.mkv",
            "58-S11E01 Mrs McGinty's Dead 清洁女工之死 - 辛巴[微软雅黑].ass"),
        isTrue,
      );
    });
  });

  group('靠集数配对', () {
    test('S10E01 前缀编号 + 中文标题', () {
      expect(
        matches(
          'S10E01.mkv',
          '54-S10E01 The Mystery of the Blue Train 蓝色列车之谜.蓝光版英中字幕.srt',
        ),
        isTrue,
      );
    });

    test('S12E01 中文标题紧贴集数', () {
      expect(
        matches(
          'S12E01.mkv',
          '62-S12E01三幕悲剧.Three.Act.Tragedy蓝光版本中英特效.srt',
        ),
        isTrue,
      );
    });

    test('集数不同就不配', () {
      expect(
        matches('S10E01.mkv', '55-S10E02 另一个标题.中英字幕.srt'),
        isFalse,
      );
    });
  });

  // 数字后面跟标点：发布组最常见的命名。早先这种写法两边都认不出集数，
  // 于是掉进 Dice 近似判定 —— `show name 01` 与 `show name 02` 相似度约
  // 0.909，整季字幕会被判成同一片挂到每一集上。用例与内核
  // `native/tests/lp_submatch_test.c` 保持一一对应。
  group('数字后面跟标点也算集数', () {
    test('方括号后跟分辨率：集数不同不配', () {
      expect(
        matches(
          '[Group] Show Name - 01 [1080p].mkv',
          '[Group] Show Name - 02.chs.ass',
        ),
        isFalse,
      );
    });

    test('方括号后跟分辨率：集数相同要配', () {
      expect(
        matches(
          '[Group] Show Name - 01 [1080p].mkv',
          '[Group] Show Name - 01.chs.ass',
        ),
        isTrue,
      );
    });

    test('短横线分隔的集数', () {
      expect(matches('Show - 03.mkv', 'Show - 04.zh.srt'), isFalse);
    });

    test('第 N 集写法', () {
      expect(matches('白箱第12集.mkv', '白箱第13集.ass'), isFalse);
      expect(matches('白箱第12集.mkv', '白箱第12集.ass'), isTrue);
    });

    test('独立 E 编号', () {
      expect(matches('Show - E03.mkv', 'Show - E04.chs.ass'), isFalse);
    });

    test('四位年份不当集数', () {
      expect(
        matches('Blade.Runner.2049.2017.mkv', 'Blade.Runner.2049.2017.zh.srt'),
        isTrue,
      );
    });
  });

  // 语言标签补全：`cn`/`tw`/`hk`/`hans`/`hant` 早先两侧都漏了，
  // 最普通的 `Movie.2024.1080p.mkv` + `Movie.2024.zh-CN.srt` 会被判否。
  group('语言标签补全', () {
    test('zh-CN', () {
      expect(matches('Movie.2024.1080p.mkv', 'Movie.2024.zh-CN.srt'), isTrue);
    });

    test('hans', () {
      expect(matches('Movie.2024.1080p.mkv', 'Movie.2024.hans.ass'), isTrue);
    });
  });

  group('边界', () {
    test('完全无关的字幕', () {
      expect(matches('movie.mkv', 'other.srt'), isFalse);
    });

    test('没有扩展名也能比较', () {
      expect(matches('movie', 'movie.zh.srt'), isTrue);
    });
  });
}
