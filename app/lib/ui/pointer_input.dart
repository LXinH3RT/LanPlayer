import 'dart:io' show Platform;

/// 当前宿主是不是「鼠标驱动」的。
///
/// 用「有没有鼠标」而不是「是不是移动端」来分档，是因为这两件事在桌面端
/// 并不等价：Windows 上还有触屏笔记本，但那台机器上点画面的人和拿鼠标的
/// 人期待的是同一件事，控制栏本来就会跟着鼠标移动出现，不需要再靠点击去叫。
bool get isMouseDrivenHost =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 在播放画面上单击一下应该做什么。
enum SurfaceTapAction {
  /// 播放 / 暂停。桌面端的旧行为。
  togglePlay,

  /// 把控制栏叫出来。触屏宿主的行为。
  revealControls,
}

/// 单击画面的语义分档。
///
/// 判定抽成纯函数，好让两个平台各自的行为都有测试盯着 —— 播放页里那段
/// 分支没法在 widget 测试里跑（要真的建一条播放内核），而「谁该暂停、谁该
/// 叫控制栏」恰恰是最容易在后续重构里被改错的地方。
SurfaceTapAction surfaceTapAction({required bool mouseDriven}) =>
    mouseDriven ? SurfaceTapAction.togglePlay : SurfaceTapAction.revealControls;
