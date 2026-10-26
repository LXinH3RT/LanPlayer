import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/widgets/video_surface.dart';

/// 「画面」面板里的三个缩放选项在桌面端点了没反应（用户报的缺陷）。根因是
/// 内核的 `scale_mode` 只有 Android EGL 会读，桌面与 iOS 走 Flutter 外部纹理，
/// 没有任何人消费它。现在改由 [VideoSurface] 在 Flutter 层做，这几个用例把
/// 「三种模式真的映射到不同的贴合方式」钉住。
void main() {
  test('缩放模式映射到 BoxFit', () {
    expect(VideoSurface.fitFor(scaleModeFit), BoxFit.contain);
    expect(VideoSurface.fitFor(scaleModeFill), BoxFit.cover);
    expect(VideoSurface.fitFor(scaleModeStretch), BoxFit.fill);
    // 未知取值退回「适应屏幕」，不能崩。
    expect(VideoSurface.fitFor(99), BoxFit.contain);
    expect(VideoSurface.fitFor(-1), BoxFit.contain);
  });

  Future<FittedBox> pumpSurface(
    WidgetTester tester, {
    required int mode,
    double ratio = 16 / 9,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: VideoSurface(
                scaleMode: mode,
                videoAspectRatio: ratio,
                child: const ColoredBox(color: Colors.green),
              ),
            ),
          ),
        ),
      ),
    );
    return tester.widget<FittedBox>(find.byType(FittedBox));
  }

  testWidgets('三种模式给出三种不同的贴合方式', (tester) async {
    final fit = await pumpSurface(tester, mode: scaleModeFit);
    expect(fit.fit, BoxFit.contain);
    // 盒子的宽高比必须是视频本身的，否则铺满裁切会按窗口比例放大而变形。
    final box = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(FittedBox),
        matching: find.byType(SizedBox),
      ),
    );
    expect(box.width! / box.height!, closeTo(16 / 9, 1e-6));

    expect((await pumpSurface(tester, mode: scaleModeFill)).fit, BoxFit.cover);
    expect(
        (await pumpSurface(tester, mode: scaleModeStretch)).fit, BoxFit.fill);
  });

  testWidgets('宽高比无效时退回 16:9 而不是抛异常', (tester) async {
    for (final bad in [0.0, double.nan, double.infinity, -2.0]) {
      final f = await pumpSurface(tester, mode: scaleModeFit, ratio: bad);
      final box = tester.widget<SizedBox>(
        find.descendant(
          of: find.byType(FittedBox),
          matching: find.byType(SizedBox),
        ),
      );
      expect(box.width! / box.height!, closeTo(16 / 9, 1e-6),
          reason: 'ratio=$bad 应退回 16:9');
      expect(f.fit, BoxFit.contain);
    }
  });

  testWidgets('改 scaleMode 后同一棵树上的 FittedBox 跟着换', (tester) async {
    var mode = scaleModeFit;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (ctx, setState) {
              setOuter = setState;
              return Center(
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: VideoSurface(
                    scaleMode: mode,
                    videoAspectRatio: 2.0,
                    child: const ColoredBox(color: Colors.green),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(
        tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.contain);

    // 面板里的做法就是改 settings.scaleMode 再 setState，这里照做。
    setOuter(() => mode = scaleModeFill);
    await tester.pump();
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);

    setOuter(() => mode = scaleModeStretch);
    await tester.pump();
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.fill);
  });
}
