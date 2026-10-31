import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/background.dart';
import 'package:lanplayer/core/bindings.dart';
import 'package:lanplayer/data/repository.dart';

/// 「列表请求不能在 UI 线程上跑」的回归测试。
///
/// 回归背景：内核的 `lp_source_list` 是同步 C 函数，服务器不响应时要等到
/// socket 超时（默认 15 s）。它原先直接在主 isolate 上调用，整个界面就冻住：
/// 窗口一片白、按钮点了没水波纹、转圈不动、点「重试」毫无反应。0.1.7 装到
/// 没有开 SMB 的机器上就是这个样子。
///
/// 这里能验证的部分是「仓库层确实把请求交给了可替换的取数实现」，真正的
/// isolate 隔离由 `listDirectoryInBackground` 保证（它内部就是 `Isolate.run`），
/// 而 `Isolate.run` 在测试进程里没法观察线程归属。所以测试分两层：
///   1. 默认实现必须是后台 isolate 那个函数（对象同一性）；
///   2. 换一个会挂起的取数实现时，仓库的 Future 不能同步完成 —— 说明它
///      至少不是「同步调完直接返回」。
void main() {
  test('默认的取数实现就是后台 isolate 那个', () {
    final repo = MediaRepository();
    expect(repo.fetchListingForTest, same(listDirectoryInBackground));
  });

  /// 评审 4.8：盘符探测会同步 stat，掉线的网络盘要等系统重试好几秒。
  /// 它必须在后台 isolate 上跑，而且测试要能换掉它 —— 否则测一次就要真去
  /// 碰一遍本机所有盘符。
  test('盘符探测默认也交给后台 isolate，并且可以被替换', () async {
    expect(MediaRepository().driveScannerForTest,
        same(windowsDriveRootsInBackground));

    final repo = MediaRepository(
      scanDrives: () async => <String>['C:\\', 'D:\\'],
    );
    final roots = await repo.localRoots();
    expect(roots.map((r) => r.label), containsAll(<String>['C 盘', 'D 盘']));
    expect(roots.where((r) => r.path == 'C:\\'), hasLength(1));
  });

  test('localRoots 不会在调用返回前就完成（盘符探测是异步的）', () async {
    var scanned = false;
    final repo = MediaRepository(
      scanDrives: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        scanned = true;
        return const <String>[];
      },
    );

    final future = repo.localRoots();
    // 同步实现会在这里就已经扫完，界面要等它；异步实现让页面先画出来。
    expect(scanned, isFalse);
    await future;
    expect(scanned, isTrue);
  });

  test('列目录不会在调用返回前就完成', () async {
    var finished = false;
    final repo = MediaRepository(
      fetchListing: (url, options) async {
        // 模拟一次要等一阵子的网络往返。
        await Future<void>.delayed(const Duration(milliseconds: 40));
        finished = true;
        return ListingResult.json('{"url":"$url","parent":"","entries":[]}');
      },
    );

    final future = repo.browseUrl('smb://host/share', const {});
    // 关键断言：函数已经返回，但请求还没完成 —— 界面在这段时间里可以照常
    // 渲染。同步实现会在这里就 finished == true。
    expect(finished, isFalse);

    final listing = await future;
    expect(finished, isTrue);
    expect(listing.entries, isEmpty);
  });

  test('请求失败时给的不是内核原文，而是一句能读懂的话', () async {
    final repo = MediaRepository(
      fetchListing: (url, options) async => ListingResult.failure(
          const SourceFailure(code: SourceFailure.timeout)),
    );
    await expectLater(
      repo.browseUrl('smb://host/share', const {}),
      throwsA(isA<MediaSourceException>().having(
        (e) => e.message,
        'message',
        allOf(contains('smb://host/share'), contains('超时')),
      )),
    );
  });

  /// 内核分得出「密码错」和「连不上」，这两句话必须不一样 —— 前者要去改
  /// 账号密码，后者要去查网线和端口。以前两者都是同一句「连接超时或服务器
  /// 不可达」，用户照着它排查是白费力气。
  test('不同失败原因给不同的提示', () async {
    Future<String> messageFor(int? code) async {
      final repo = MediaRepository(
        fetchListing: (url, options) async =>
            ListingResult.failure(SourceFailure(code: code)),
      );
      try {
        await repo.browseUrl('smb://host/share', const {});
      } on MediaSourceException catch (e) {
        return e.message;
      }
      fail('应当抛出 MediaSourceException');
    }

    final auth = await messageFor(SourceFailure.auth);
    final notFound = await messageFor(SourceFailure.notFound);
    final timeout = await messageFor(SourceFailure.timeout);
    final io = await messageFor(SourceFailure.io);

    expect(auth, contains('账号或密码'));
    expect(notFound, contains('路径不存在'));
    expect(timeout, contains('超时'));
    expect(io, contains('连接失败'));
    expect({auth, notFound, timeout, io}.length, 4, reason: '四类失败不能是同一句话');
    // 内核没给分类时退回通用说法，不能崩。
    expect(await messageFor(null), contains('连接失败'));
  });
}
