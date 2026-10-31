import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';

/// 浏览列表的两个契约：
///   1. 只显示目录 / 视频 / 音频 —— `.txt`、`.docx` 不出现；
///   2. 字幕归属于对应的视频，且不会误配（`movie2.srt` 不能挂到 `movie.mkv`）。
void main() {
  MediaEntry file(String name, {String? kind}) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    final inferred = switch (ext) {
      'mkv' || 'mp4' || 'flv' || 'avi' || 'mov' => 'video',
      'srt' || 'ass' || 'ssa' || 'vtt' || 'sub' => 'subtitle',
      'mp3' || 'aac' || 'flac' => 'audio',
      'txt' || 'docx' || 'ini' || 'pdf' => 'other',
      _ => 'other',
    };
    return MediaEntry(
      name: name,
      path: 'smb://h/s/$name',
      isDir: false,
      size: 100,
      kind: kind ?? inferred,
      ext: ext,
    );
  }

  MediaEntry dir(String name) => MediaEntry(
        name: name,
        path: 'smb://h/s/$name',
        isDir: true,
        size: 0,
        kind: 'dir',
        ext: '',
      );

  DirectoryListing listing(List<MediaEntry> entries) =>
      DirectoryListing(url: 'smb://h/s', parent: '', entries: entries);

  group('浏览列表只保留媒体', () {
    test('.txt / .docx 不出现在列表里', () {
      final l = listing([
        dir('电影'),
        file('movie.mkv'),
        file('movie.srt'),
        file('说明.txt'),
        file('笔记.docx'),
        file('desktop.ini'),
        file('song.mp3'),
      ]);
      final names = l.browsable.map((e) => e.name).toList();
      expect(names, contains('电影'));
      expect(names, contains('movie.mkv'));
      expect(names, contains('song.mp3'), reason: '音频仍要显示（可播放）');
      expect(names, isNot(contains('movie.srt')), reason: '字幕已归到视频下面');
      expect(names, isNot(contains('说明.txt')));
      expect(names, isNot(contains('笔记.docx')));
      expect(names, isNot(contains('desktop.ini')));
    });

    test('目录永远保留，否则进不去子文件夹', () {
      final l = listing([dir('A'), dir('B'), file('x.mkv')]);
      expect(l.browsable.where((e) => e.isDir).length, 2);
    });

    test('没有视频认领的字幕仍显示（标为未关联），不能凭空消失', () {
      // 真实场景：`anime-01013.ass` 有字幕但没有 013 视频。
      final l = listing([
        file('a001.mkv'),
        file('a001.ass'),
        file('a013.ass'),
      ]);
      final names = l.browsable.map((e) => e.name).toList();
      expect(names, contains('a001.mkv'));
      expect(names, isNot(contains('a001.ass')), reason: '已归属，不单独占行');
      expect(names, contains('a013.ass'), reason: '无主字幕要保留');
      expect(l.orphanSubtitles.map((e) => e.name), ['a013.ass']);
    });

    test('字幕比视频多时也不丢', () {
      final l = listing([
        file('a.mkv'),
        file('a.srt'),
        file('b.srt'),
        file('c.srt'),
      ]);
      final shown = l.browsable.map((e) => e.name).toSet();
      expect(shown, {'a.mkv', 'b.srt', 'c.srt'});
      expect(l.orphanSubtitles.length, 2);
    });
  });

  group('字幕归属', () {
    test('同名不同扩展名', () {
      final video = file('电影.mkv');
      final l = listing([video, file('电影.srt')]);
      expect(l.subtitlesFor(video).map((e) => e.name), ['电影.srt']);
    });

    test('带语言后缀：movie.zh-CN.srt / movie.eng.ass', () {
      final video = file('movie.mkv');
      final l = listing([
        video,
        file('movie.zh-CN.srt'),
        file('movie.eng.ass'),
        file('movie.chs&eng.srt'),
      ]);
      expect(l.subtitlesFor(video).length, 3);
    });

    test('不会把 movie2.srt 错配给 movie.mkv', () {
      final video = file('movie.mkv');
      final l = listing([video, file('movie2.srt'), file('movie.zh.srt')]);
      final got = l.subtitlesFor(video).map((e) => e.name).toList();
      expect(got, ['movie.zh.srt']);
      expect(got, isNot(contains('movie2.srt')));
    });

    test('剧集：S01E01 与 S01E02 的字幕各归各的', () {
      final e1 = file('Show.S01E01.mkv');
      final e2 = file('Show.S01E02.mkv');
      final l = listing([
        e1, e2,
        file('Show.S01E01.zh.srt'),
        file('Show.S01E02.zh.srt'),
        file('Show.S01E01.eng.srt'),
      ]);
      expect(l.subtitlesFor(e1).map((e) => e.name),
          ['Show.S01E01.zh.srt', 'Show.S01E01.eng.srt']);
      expect(l.subtitlesFor(e2).map((e) => e.name), ['Show.S01E02.zh.srt']);
    });

    test('大小写不敏感', () {
      final video = file('Movie.MKV');
      final l = listing([video, file('movie.zh.SRT')]);
      expect(l.subtitlesFor(video).length, 1);
    });

    test('分隔符也认 - _ 空格', () {
      final video = file('movie.mkv');
      final l = listing([
        video,
        file('movie - zh.srt'),
        file('movie_chs.srt'),
        file('movie (1).srt'),
      ]);
      expect(l.subtitlesFor(video).length, 3);
    });

    test('没有对应字幕时返回空', () {
      final video = file('movie.mkv');
      final l = listing([video, file('other.srt')]);
      expect(l.subtitlesFor(video), isEmpty);
    });

    test('音频不参与字幕归属', () {
      final audio = file('song.mp3');
      final l = listing([audio, file('song.srt')]);
      expect(l.subtitlesFor(audio), isEmpty);
    });
  });

  group('派生列表只算一次', () {
    test('下标表与逐个扫描给出同一结果', () {
      final v1 = file('Show.S01E01.mkv');
      final v2 = file('Show.S01E02.mkv');
      final s1 = file('Show.S01E01.zh.srt');
      final s2 = file('Show.S01E02.zh.srt');
      final stray = file('a013.ass');
      final l = listing([dir('季'), v1, v2, s1, s2, stray, file('song.mp3')]);

      // 与「每次重新扫一遍」的朴素实现逐项对齐 —— 缓存不许改变结果。
      List<MediaEntry> naive(MediaEntry v) =>
          l.entries.where((e) => e.isSubtitle &&
              subtitleBelongsTo(v.name, e.name)).toList();
      for (final v in [v1, v2]) {
        expect(l.subtitlesFor(v).map((e) => e.path),
            naive(v).map((e) => e.path));
      }
      expect(l.orphanSubtitles.map((e) => e.name), ['a013.ass']);
      expect(l.subtitlesFor(s1), isEmpty);
    });

    test('重复读拿到同一个 List 实例（真的是缓存，不是每次重建）', () {
      final v = file('movie.mkv');
      final l = listing([v, file('movie.zh.srt')]);
      expect(identical(l.browsable, l.browsable), isTrue);
      expect(identical(l.videos, l.videos), isTrue);
      expect(identical(l.orphanSubtitles, l.orphanSubtitles), isTrue);
      expect(identical(l.subtitlesFor(v), l.subtitlesFor(v)), isTrue);
    });

    test('ownerOfSubtitle 指出归属，无主字幕返回 null', () {
      final v = file('movie.mkv');
      final owned = file('movie.zh.srt');
      final stray = file('a013.ass');
      final l = listing([v, owned, stray]);
      expect(l.ownerOfSubtitle(owned)?.path, v.path);
      expect(l.ownerOfSubtitle(stray), isNull);
    });

    test('多个视频都能认领同一份字幕时，归属取列表里靠前的那个', () {
      // `电影.mkv` 与 `电影.CD2.mkv` 都可能匹配 `电影.zh.srt`；列表顺序决定
      // 谁先认领，和改缓存之前的行为一致。
      final a = file('电影.mkv');
      final b = file('电影.CD2.mkv');
      final shared = file('电影.zh.srt');
      final l = listing([a, b, shared]);
      expect(l.subtitlesFor(a).map((e) => e.name), ['电影.zh.srt']);
      expect(l.ownerOfSubtitle(shared)?.path, a.path);
    });
  });
}
