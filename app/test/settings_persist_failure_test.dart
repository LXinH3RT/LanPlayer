import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';
import 'package:lanplayer/ui/theme.dart';

/// 设置页写盘失败时要说出来。
///
/// 回归背景：`_persist()` 以前是裸 `await SettingsStore.instance.save()`，
/// 抛出来的异常没人接 —— 用户拨了一排开关、界面全部显示为已生效，重启之后
/// 一个都没留下，而且全场没有任何提示。真机上磁盘写不进去几乎不可复现
/// （`AppStorage` 已经把「目录能不能写」探过一遍），所以这里从
/// `SettingsStore.writerOverride` 注入一个必然失败的落盘动作。
void main() {
  tearDown(() {
    SettingsStore.writerOverride = null;
    ThemeController.instance.reset();
  });

  Future<void> pump(WidgetTester tester, SettingsTab tab) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LanPlayerTheme.dark(),
      home: SettingsScreen(initialTab: tab),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('写盘失败时给出提示，而不是静默吞掉', (tester) async {
    SettingsStore.instance.value = PlaybackSettings();
    SettingsStore.writerOverride =
        (PlaybackSettings _) async => throw const FileSystemException(
              'write failed',
              '/somewhere/settings.json',
              OSError('No space left on device', 28),
            );
    await pump(tester, SettingsTab.appearance);

    await tester.tap(find.byKey(const ValueKey('settings-theme-light')));
    // 落盘是 200 ms 去抖的，等它到点。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('设置没能保存到磁盘'), findsOneWidget);
    // 提示里不能出现本机路径或异常原文。
    expect(find.textContaining('/somewhere'), findsNothing);
  });

  testWidgets('失败提示只弹一次，连着拨开关不会刷屏', (tester) async {
    SettingsStore.instance.value = PlaybackSettings();
    SettingsStore.writerOverride =
        (PlaybackSettings _) async => throw const FileSystemException('nope');
    await pump(tester, SettingsTab.appearance);

    await tester.tap(find.byKey(const ValueKey('settings-theme-light')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置没能保存到磁盘'), findsOneWidget);

    // 再拨一次：不重复提示（提示条本身还在）。
    await tester.tap(find.byKey(const ValueKey('settings-theme-system')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置没能保存到磁盘'), findsOneWidget);
  });

  testWidgets('写盘正常时没有任何提示', (tester) async {
    SettingsStore.instance.value = PlaybackSettings();
    var writes = 0;
    SettingsStore.writerOverride = (PlaybackSettings _) async {
      writes++;
    };
    await pump(tester, SettingsTab.appearance);

    await tester.tap(find.byKey(const ValueKey('settings-theme-light')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(writes, 1);
    expect(find.textContaining('设置没能保存到磁盘'), findsNothing);
  });
}
