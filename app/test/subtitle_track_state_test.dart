import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';

/// 字幕弹框的两栏划分。
///
/// 内核报的轨道表是唯一真话来源：`selected` 标着当前显示的是哪一条，外挂轨的
/// `title` 就是文件名。用户报过「点了一份外挂字幕，确实读进去了，但界面还显示
/// 默认字幕」——那是选中项没换。这些用例把「文件名列表」到「该不该出现在待选
/// 栏」这段纯逻辑钉住。
///
/// 轨道表形状取自真实内核输出（内嵌 subrip + 一条外挂 ass）：
/// ```
/// {"index":2,"codec":"subrip","lang":"zh","title":"Embedded","external":false,"selected":true}
/// {"index":1001,"codec":"ass","lang":"","title":"film.ass","external":true,"selected":false}
/// ```
MediaInfo _info(List<Map<String, dynamic>> subs) => MediaInfo.fromJson({
      'duration_us': 60000000,
      'format': 'matroska',
      'bitrate': 8000000,
      'video': {'width': 1920, 'height': 1080, 'codec': 'h264'},
      'audio': const [],
      'subtitle': subs,
      'hw': {'active': 'software'},
    });

Map<String, dynamic> _embedded({bool selected = false, int index = 2}) => {
      'index': index,
      'codec': 'subrip',
      'lang': 'zh',
      'title': 'Embedded',
      'external': false,
      'selected': selected,
    };

Map<String, dynamic> _external(
  String name, {
  bool selected = false,
  int index = 1001,
}) =>
    {
      'index': index,
      'codec': 'ass',
      'lang': '',
      'title': name,
      'external': true,
      'selected': selected,
    };

void main() {
  test('内嵌轨被选中时索引就是它，没有外挂轨在显示', () {
    final info = _info([_embedded(selected: true)]);
    expect(selectedSubtitleIndex(info), 2);
    expect(activeExternalSubtitleTitle(info), isNull);
  });

  test('点过一份外挂字幕之后它成了选中轨', () {
    final info = _info([
      _embedded(),
      _external('film.ass', selected: true, index: 1001),
    ]);
    expect(selectedSubtitleIndex(info), 1001);
    expect(activeExternalSubtitleTitle(info), 'film.ass');
  });

  test('换回内嵌轨时选中索引回到内嵌', () {
    final info = _info([
      _embedded(selected: true),
      _external('film.ass', index: 1001),
      _external('movie.ass', index: 1002),
    ]);
    expect(selectedSubtitleIndex(info), 2);
    expect(activeExternalSubtitleTitle(info), isNull);
  });

  test('一条轨都没选时索引是哨兵值', () {
    expect(selectedSubtitleIndex(_info([_embedded(index: 2)])),
        noSubtitleTrack);
    expect(selectedSubtitleIndex(_info(const [])), noSubtitleTrack);
  });

  test('按文件名找回已加载的外挂轨索引，没加载过是哨兵值', () {
    final info = _info([
      _embedded(),
      _external('film.ass', index: 1001),
      _external('movie.ass', selected: true, index: 1002),
    ]);
    expect(externalSubtitleIndexOf('film.ass', info), 1001);
    expect(externalSubtitleIndexOf('movie.ass', info), 1002);
    expect(externalSubtitleIndexOf('other.ass', info), noSubtitleTrack);
  });

  test('内嵌轨不会被当成外挂文件命中', () {
    // 内嵌轨的 title 可能跟某个字幕文件名撞上（内嵌轨也带标题），不能因此
    // 就把那份外挂文件当成「已加载」而从待选栏里拿掉。
    final info = _info([
      {'index': 2, 'codec': 'subrip', 'lang': 'zh', 'title': 'film.ass',
       'external': false, 'selected': true},
    ]);
    expect(externalSubtitleIndexOf('film.ass', info), noSubtitleTrack);
  });

  test('待选栏只列还没进轨道表的文件', () {
    final info = _info([
      _embedded(),
      _external('film.ass', selected: true, index: 1001),
    ]);
    // 两份都在目录里，film.ass 已经加载过，只剩 movie.ass 待选。
    expect(
      pendingSubtitleFiles(['film.ass', 'movie.ass'], (s) => s, info),
      ['movie.ass'],
    );
  });

  test('一份都没加载时待选栏原样返回', () {
    final info = _info([_embedded(selected: true)]);
    expect(
      pendingSubtitleFiles(['film.ass', 'movie.ass'], (s) => s, info),
      ['film.ass', 'movie.ass'],
    );
  });

  test('全部加载过时待选栏为空，避免同一份字幕显示两次', () {
    final info = _info([
      _embedded(),
      _external('film.ass', index: 1001),
      _external('movie.ass', index: 1002),
    ]);
    expect(
      pendingSubtitleFiles(['film.ass', 'movie.ass'], (s) => s, info),
      isEmpty,
    );
  });

  test('文件列表为空时待选栏也为空', () {
    expect(
      pendingSubtitleFiles(const <String>[], (s) => s, _info([_embedded()])),
      isEmpty,
    );
  });
}
