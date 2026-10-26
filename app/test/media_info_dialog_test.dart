import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/widgets/media_info_dialog.dart';

/// 用户要求「把媒体信息和解码信息合并为一项功能」：原来「画面」面板里是
/// 两行 —— 一行开关控制左上角浮层，一行弹对话框。现在并成一个面板，静态
/// 码流参数和实时解码计数同屏，浮层开关作为面板里的一格。
void main() {
  const video = VideoInfo(
    width: 1920,
    height: 1080,
    codec: 'h264',
    fps: 23.976,
    pixFmt: 'yuv420p',
    bitrate: 8500000,
  );
  const audio = AudioTrack(
    index: 1,
    codec: 'aac',
    channels: 2,
    sampleRate: 48000,
    lang: 'eng',
    title: '',
  );
  const media = MediaInfo(
    durationUs: 7234000000,
    format: 'matroska,webm',
    bitrate: 9000000,
    video: video,
    audio: [audio],
    subtitles: [],
    hw: 'd3d11va',
  );

  MediaStatsSnapshot snapshot({
    String decoder = 'd3d11va',
    double fps = 23.98,
    int dropped = 0,
    int positionUs = 61000000,
  }) =>
      MediaStatsSnapshot(
        media: media,
        decoder: decoder,
        fps: fps,
        dropped: dropped,
        avDiffUs: -12000,
        queuedPackets: 34,
        positionUs: positionUs,
      );

  Future<void> pumpDialog(
    WidgetTester tester, {
    required ValueListenable<MediaStatsSnapshot> source,
    bool overlay = false,
    ValueChanged<bool>? onOverlayChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MediaInfoDialog(
          read: () => source.value,
          listen: source,
          overlay: overlay,
          onOverlayChanged: onOverlayChanged ?? (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('一个面板同时显示媒体参数与解码计数', (tester) async {
    final source = ValueNotifier(snapshot());
    addTearDown(source.dispose);
    await pumpDialog(tester, source: source);

    expect(find.text('媒体信息'), findsOneWidget);
    // 静态参数（原来只有对话框里有）
    expect(find.text('matroska,webm'), findsOneWidget);
    expect(find.text('h264 1920x1080 23.98fps'), findsOneWidget);
    expect(find.text('yuv420p'), findsOneWidget);
    expect(find.text('8500 kbps'), findsOneWidget);
    expect(find.text('ENG · 2 ch · aac'), findsOneWidget);
    // 实时计数（原来只有浮层里有）
    expect(find.text('d3d11va'), findsOneWidget);
    expect(find.text('23.98 fps'), findsOneWidget);
    expect(find.text('34 包'), findsOneWidget);
    expect(find.text('-12.0 ms'), findsOneWidget);
    expect(find.text('01:01 / 02:00:34'), findsOneWidget);
    // 两段小标题都在，说明确实合并成一个面板
    expect(find.text('媒体'), findsOneWidget);
    expect(find.text('解码'), findsOneWidget);
  });

  testWidgets('统计数字变化时面板自己刷新', (tester) async {
    final source = ValueNotifier(snapshot());
    addTearDown(source.dispose);
    await pumpDialog(tester, source: source);
    expect(find.text('23.98 fps'), findsOneWidget);

    source.value = snapshot(
        decoder: 'software', fps: 12.5, dropped: 7, positionUs: 120000000);
    await tester.pump();
    expect(find.text('software'), findsOneWidget);
    expect(find.text('12.50 fps'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('02:00 / 02:00:34'), findsOneWidget);
    // 旧的读数不能还留着
    expect(find.text('23.98 fps'), findsNothing);
  });

  testWidgets('面板里的浮层开关能打开也能关掉', (tester) async {
    final source = ValueNotifier(snapshot());
    addTearDown(source.dispose);
    final calls = <bool>[];
    await pumpDialog(tester, source: source, onOverlayChanged: calls.add);

    final sw = find.byType(SwitchListTile);
    expect(sw, findsOneWidget);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);

    await tester.ensureVisible(sw);
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect(calls, [true]);

    await tester.ensureVisible(sw);
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(calls, [true, false]);
  });

  testWidgets('打开时已经开着浮层，面板里的开关是选中态', (tester) async {
    final source = ValueNotifier(snapshot());
    addTearDown(source.dispose);
    await pumpDialog(tester, source: source, overlay: true);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
  });
}
