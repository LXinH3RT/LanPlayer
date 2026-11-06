import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/core/bindings.dart';
import 'package:lanplayer/core/player_controller.dart';
import 'package:lanplayer/data/models.dart';

/// 事件分发的行为契约。
///
/// 回归背景：事件是内核从自己的 worker 线程经 `NativeCallable.listener` 送进来的，
/// 每条都带一段 JSON。这些分支里有三条以前出过事 —— 空 payload 把 MEDIA_INFO
/// 刚给的列表洗掉、未确定的时长把整页重建、错误事件不停掉缓冲态 —— 而它们全都
/// 走不到界面单测（那需要真的播一个坏文件）。这里直接喂构造出来的事件。
void main() {
  /// 复制一份 controller 的事件入口。
  ///
  /// `_handleEvent` 是私有的，参数里还带 `Pointer<Utf8>`。把它拆成可测的样子
  /// 要动生产代码的形状，所以这里只在测试里重建同样的分发逻辑 —— 这不能防止
  /// 生产代码被改坏，能防的是「改完之后大家忘了这三条语义」。真正的护栏是
  /// `tool/check_all.py` 里的源码断言。
  void dispatch(PlayerController c, int event, Map<String, dynamic> map) {
    switch (event) {
      case LpEvent.state:
        c.state = playerStateFromInt((map['state'] as num?)?.toInt() ?? 0);
        if (c.state == PlayerState.error) c.buffering = false;
      case LpEvent.position:
        final pos = (map['pos'] as num?)?.toInt() ?? 0;
        final dur = (map['dur'] as num?)?.toInt() ?? 0;
        c.positionUs = pos;
        c.positionUsNotifier.value = pos;
        if (dur > 0 && dur != c.durationUs) {
          c.durationUs = dur;
          c.notifyListeners();
        }
        return;
      case LpEvent.mediaInfo:
      case LpEvent.tracks:
        if (map.isEmpty) break;
        c.media = MediaInfo.fromJson(map);
        if (c.media.durationUs > 0) c.durationUs = c.media.durationUs;
        c.hwActive = c.media.hw;
        c.buffering = false;
      case LpEvent.error:
        c.error = map['message'] as String? ?? '播放失败';
        c.state = PlayerState.error;
        c.buffering = false;
      case LpEvent.ended:
        c.state = PlayerState.ended;
      case LpEvent.buffering:
        c.buffering = map['buffering'] == true;
    }
  }

  group('事件分发', () {
    test('空 payload 不会把已有轨道列表清掉', () {
      // 回归背景：老内核打开成功后会先发一条 MEDIA_INFO、再发一条空的 TRACKS。
      // 当时的实现照样 `MediaInfo.fromJson({})` 覆盖，界面于是说「内嵌字幕 0 条」。
      final c = PlayerController();
      addTearDown(c.dispose);
      dispatch(c, LpEvent.mediaInfo, <String, dynamic>{
        'duration_us': 60000000,
        'format': 'matroska',
        'bitrate': 4000000,
        'subtitle': [
          {'index': 2, 'lang': 'zh', 'title': '简体'},
          {'index': 3, 'lang': 'en', 'title': 'English'},
        ],
        'hw': {'active': 'videotoolbox'},
      });
      expect(c.media.subtitles, hasLength(2));
      expect(c.durationUs, 60000000);

      dispatch(c, LpEvent.tracks, const <String, dynamic>{});
      expect(c.media.subtitles, hasLength(2));
      expect(c.hwActive, 'videotoolbox');
    });

    test('时长没变时不重复通知，变了才通知', () {
      // 进度事件每秒 5 次，每次都 notifyListeners 会让整页控件树跟着重建。
      final c = PlayerController();
      addTearDown(c.dispose);
      var notified = 0;
      c.addListener(() => notified++);

      dispatch(c, LpEvent.position, <String, dynamic>{'pos': 1000, 'dur': 0});
      expect(notified, 0);
      // 未知时长（dur=0）不能把 durationUs 写成 0，也不能算「确定」。
      expect(c.durationUs, 0);

      dispatch(c, LpEvent.position, <String, dynamic>{'pos': 2000, 'dur': 5000000});
      expect(c.durationUs, 5000000);
      expect(notified, 1);

      dispatch(c, LpEvent.position, <String, dynamic>{'pos': 3000, 'dur': 5000000});
      expect(notified, 1);
      expect(c.positionUs, 3000);
      expect(c.positionUsNotifier.value, 3000);
    });

    test('错误事件同时停掉缓冲态', () {
      // 否则转圈动画会一直在错误提示上面转。
      final c = PlayerController();
      addTearDown(c.dispose);
      dispatch(c, LpEvent.buffering, <String, dynamic>{'buffering': true});
      expect(c.buffering, isTrue);

      dispatch(c, LpEvent.error, <String, dynamic>{'message': '连不上服务器'});
      expect(c.state, PlayerState.error);
      expect(c.error, '连不上服务器');
      expect(c.buffering, isFalse);
    });

    test('错误事件没有 message 时也有可显示的文案', () {
      final c = PlayerController();
      addTearDown(c.dispose);
      dispatch(c, LpEvent.error, const <String, dynamic>{});
      expect(c.error, isNotEmpty);
      expect(c.state, PlayerState.error);
    });
  });

  group('播放器还没打开时', () {
    test('seek / 倍速 / 音量都不动状态，也不抛', () {
      // 打开是异步的：_player 还是 null 时用户就可能拖进度条。以前这些方法
      // 直接解引用，测试环境里就是空指针。
      final c = PlayerController();
      addTearDown(c.dispose);
      c.setSpeed(9.0);
      c.setVolume(9.0);
      c.seekTo(123456);
      c.toggleMute();
      c.togglePlay();
      expect(c.speed, isNot(9.0));
      expect(c.volume, lessThanOrEqualTo(2.0));
      expect(c.positionUs, 0);
    });
  });
}
