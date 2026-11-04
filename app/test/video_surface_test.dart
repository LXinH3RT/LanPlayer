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

  // 平台视图（SurfaceView）的布局尺寸就是系统给它的图形缓冲尺寸。若沿用
  // 纹理那条路的「1000 逻辑像素高虚拟盒子」，真机上会按 1778×1000 逻辑
  // 分配出 5777×3250 物理像素的缓冲（约 76 MB 一块、三缓冲两百多兆），
  // 比整屏还大四倍。下面把「原生画面按贴合后的真实矩形布局」钉住。
  group('原生画面按真实尺寸布局', () {
    late BoxConstraints captured;

    Future<void> pumpNative(
      WidgetTester tester, {
      required int mode,
      required Size area,
      double ratio = 16 / 9,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: area.width,
                height: area.height,
                child: VideoSurface(
                  scaleMode: mode,
                  videoAspectRatio: ratio,
                  nativeSurface: true,
                  // 用约束而不是渲染尺寸来观察：原生视图拿到的紧约束就是
                  // 系统会分配的缓冲区尺寸。
                  child: LayoutBuilder(builder: (context, constraints) {
                    captured = constraints;
                    return const SizedBox();
                  }),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('原生画面不走 FittedBox 的虚拟盒子', (tester) async {
      await pumpNative(tester, mode: scaleModeFit, area: const Size(400, 300));
      expect(find.byType(FittedBox), findsNothing,
          reason: '平台视图不该被塞进 1000 逻辑像素高的虚拟盒子');
      // 关键断言：原生视图拿到的尺寸必须是区域大小按视频比例贴合后的结果，
      // 而不是那个 1000 高的虚拟盒子（后者会放大到 1778 高）。
      expect(captured.maxHeight, lessThanOrEqualTo(300.01),
          reason: '原生视图的缓冲区不能超过可用区域');
    });

    testWidgets('适应屏幕：受宽度限制时是 400×225', (tester) async {
      // 400×300 的区域放 16:9 的内容：高度撑满 300，宽度 533 超出可用宽度，
      // 所以 contain 受宽度限制，实际是 400×225。
      await pumpNative(tester, mode: scaleModeFit, area: const Size(400, 300));
      expect(captured.maxWidth, closeTo(400, 0.01));
      expect(captured.maxHeight, closeTo(225, 0.01));
    });

    testWidgets('铺满裁切：目标矩形覆盖整个区域（可越界）', (tester) async {
      await pumpNative(tester, mode: scaleModeFill, area: const Size(400, 300));
      expect(captured.maxHeight, closeTo(300, 0.01));
      // 16:9 铺满 400×300 需要 533 宽，溢出由外层 ClipRect 裁掉。
      expect(captured.maxWidth, closeTo(533.33, 0.01));
    });

    testWidgets('拉伸：正好铺满，不越界', (tester) async {
      await pumpNative(tester,
          mode: scaleModeStretch, area: const Size(400, 300));
      expect(captured.maxWidth, closeTo(400, 0.01));
      expect(captured.maxHeight, closeTo(300, 0.01));
    });
  });
}
