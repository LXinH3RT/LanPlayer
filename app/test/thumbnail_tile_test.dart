import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/widgets/thumbnail_tile.dart';

/// 列表左侧封面方块的两种状态。
///
/// 这里不测真实解码（需要内核动态库，测试环境里没有）：重点是
/// 「取不到封面时不能把整个列表拖垮」——早期版本里 `decodeThumb` 会对
/// 8 字节的旧缓存抛 RangeError，异常冒到 build 里就是红屏。
///
/// 注意不能用 `pumpAndSettle`：占位状态里有 `CircularProgressIndicator`，
/// 那是不停的动画，settle 永远不会收敛，会直接超时。
void main() {
  testWidgets('取封面过程中先显示占位图标，失败后安静退回图标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ThumbnailTile(
            url: 'smb://host/share/%E7%94%B5%E5%BD%B1/a.mkv',
            options: <String, dynamic>{'user': 'u', 'password': 'p'},
            fallback: Icons.movie_outlined,
          ),
        ),
      ),
    );

    // 第一帧：缓存里没有，显示转圈占位。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);

    // 让异步取图跑完。测试环境没有 lanplayer 动态库，取图必定失败，
    // 但必须安静地退回图标，而不是抛异常。
    //
    // 注意：`Isolate.run` 在 flutter_test 的 fake async 环境里不会被驱动，
    // 所以这里会一直停在「转圈」这一帧 —— 这正是要锁定的行为：即使
    // 内核永远不返回，界面也必须只是转圈，不能红屏、不能抛异常。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('尺寸按传入的边长渲染，并带圆角裁切', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ThumbnailTile(
            url: 'file:///D:/a.mkv',
            options: <String, dynamic>{},
            size: 72,
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final box = tester.getSize(find.byType(ThumbnailTile));
    expect(box.width, 72);
    expect(box.height, 72);
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
