import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/folders.dart';
import 'package:lanplayer/data/home_sources.dart';
import 'package:lanplayer/data/models.dart';

/// 首页把「点进去」这一步省掉之后，两个契约要能单测：
///   1. 服务器与本机文件夹拼成同一种来源，id 前缀不互相撞；
///   2. 顺序稳定 —— 先服务器后文件夹，各组内保持存储顺序，不按最近使用重排。
void main() {
  ServerProfile server(String id, String share, {String host = '192.168.1.10'}) =>
      ServerProfile(
        id: id,
        name: '',
        host: host,
        port: 445,
        share: share,
        user: 'share',
        password: '',
        createdAt: DateTime(2026, 1, 1),
      );

  LocalFolder folder(String id, String label, String path) =>
      LocalFolder(id: id, label: label, path: path);

  group('来源拼装', () {
    test('服务器在前、文件夹在后，各自保持原顺序', () {
      final srcs = buildHomeSources(
        [server('a', '共享'), server('b', '影片')],
        [
          folder('1', '下载', r'D:\media'),
          folder('2', '音乐', r'D:\music'),
        ],
      );
      expect(srcs.map((s) => s.label).toList(), ['共享', '影片', '下载', '音乐']);
      expect(srcs.map((s) => s.isServer).toList(),
          [true, true, false, false]);
    });

    test('id 带前缀，两类来源的 id 不互相覆盖', () {
      final srcs = buildHomeSources(
        [server('7', '共享')],
        [folder('7', '下载', r'D:\media')],
      );
      expect(srcs.map((s) => s.id).toList(), ['srv:7', 'dir:7']);
      expect(srcs.map((s) => s.id).toSet().length, 2);
    });

    test('服务器副标题是根地址 + 用户；文件夹副标题是路径', () {
      final srcs = buildHomeSources(
        [server('a', '共享')],
        [folder('1', '下载', r'D:\media')],
      );
      expect(srcs[0].subtitle, 'smb://192.168.1.10/共享  ·  用户 share');
      expect(srcs[1].subtitle, r'D:\media');
    });

    test('文件夹没起名字时用路径最后一段', () {
      final srcs = buildHomeSources([], [folder('1', '', r'D:\media\movies')]);
      expect(srcs.single.label, 'movies');
    });

    test('本地来源的 URL 指向磁盘，而不是 SMB', () {
      final srcs = buildHomeSources([], [folder('1', '下载', r'D:\media')]);
      expect(srcs.single.location.rootUrl, r'file://D:\media');
      expect(srcs.single.location.isLocal, isTrue);
    });

    test('空存储时没有来源', () {
      expect(buildHomeSources([], []), isEmpty);
    });
  });

  group('首页行的口径', () {
    MediaEntry entry(String name, String kind) => MediaEntry(
          name: name,
          path: 'smb://h/s/$name',
          isDir: kind == 'dir',
          size: 1,
          kind: kind,
          ext: '',
        );

    test('只留 目录/视频/音频；字幕归到视频下面，不单独成行', () {
      final listing = DirectoryListing(
        url: 'smb://h/s',
        parent: '',
        entries: [
          entry('电影', 'dir'),
          entry('a.mkv', 'video'),
          entry('a.srt', 'subtitle'),
          entry('b.flac', 'audio'),
          entry('notes.txt', 'other'),
          entry('notes.docx', 'other'),
        ],
      );
      // 字幕不占行：否则首页会出现一列点不开的 .srt，
      // 它们应该跟着 a.mkv 一起显示（由 media_row 负责）。
      expect(homeRows(listing).map((e) => e.name).toList(),
          ['电影', 'a.mkv', 'b.flac']);
    });
  });

  group('筛选条', () {
    test('只有一块来源时不显示', () {
      expect(showSourceFilter(0), isFalse);
      expect(showSourceFilter(1), isFalse);
    });

    test('两块及以上才显示', () {
      expect(showSourceFilter(2), isTrue);
      expect(showSourceFilter(5), isTrue);
    });
  });

  group('本机文件夹记录的读写', () {
    test('往返不丢字段', () {
      final f = folder('dir-1', '下载', r'D:\media');
      f.lastUsedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final back = LocalFolder.fromJson(f.toJson());
      expect(back.id, 'dir-1');
      expect(back.label, '下载');
      expect(back.path, r'D:\media');
      expect(back.createdAt.millisecondsSinceEpoch, f.createdAt.millisecondsSinceEpoch);
      expect(back.lastUsedAt!.millisecondsSinceEpoch, 1700000000000);
    });

    test('时间戳写成字符串也读得回来', () {
      final back = LocalFolder.fromJson({
        'id': 'dir-2',
        'label': '影片',
        'path': r'D:\movies',
        'createdAt': '1700000000000',
      });
      expect(back.createdAt.millisecondsSinceEpoch, 1700000000000);
      expect(back.lastUsedAt, isNull);
    });

    test('缺字段的记录不抛异常', () {
      final back = LocalFolder.fromJson({});
      expect(back.id, '');
      expect(back.path, '');
    });
  });

  group('单文件来源', () {
    test('老记录没写 isFile 时按目录处理', () {
      final back = LocalFolder.fromJson({'id': 'dir-3', 'path': r'D:\movies'});
      expect(back.isFile, isFalse);
    });

    test('isFile 能存进去也能读回来', () {
      final f = LocalFolder.fromJson({
        'id': 'dir-4',
        'label': '电影.mkv',
        'path': r'D:\movies\电影.mkv',
        'isFile': true,
      });
      expect(f.isFile, isTrue);
      expect(LocalFolder.fromJson(f.toJson()).isFile, isTrue);
    });

    test('文件来源在首页只有一行，且标出一个「播放」入口', () {
      final srcs = buildHomeSources(
        [],
        [
          LocalFolder(
              id: 'dir-5', label: '电影.mkv', path: r'D:\movies\电影.mkv',
              isFile: true),
        ],
      );
      expect(srcs.single.isFile, isTrue);
      expect(srcs.single.label, '电影.mkv');
      expect(srcs.single.location.rootUrl, r'file://D:\movies\电影.mkv');
    });
  });
}
