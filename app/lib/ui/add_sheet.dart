import 'package:flutter/material.dart';

import '../data/trace.dart';

/// 「添加」菜单用的底部弹层。
///
/// 与 `showModalBottomSheet` 的两点差别，都是真机上踩出来的：
///
/// 1. **必须等退场动画走完再压新页面。** `showModalBottomSheet` 返回的
///    future 是路由的 `popped`，导航栈刚决定 pop 它就完成了，可 sheet 还要
///    再滑两百毫秒。iOS 上紧接着 push，新页面会被 UIKit 丢掉 —— 用户看到
///    的就是「点加号弹出的二级页面立刻自己收回」。所以要等到 `completed`。
/// 2. **遮罩要认得幽灵触点。** iPadOS 上这个菜单会自己收回：真机日志里
///    每次都是「push 之后约 348 毫秒出现一个坐标恰好是 (0,0)、时长约
///    15 毫秒的指针事件，紧接着就是 `Navigator.maybePop`」，六次全落在
///    348.2–348.8ms，整齐得不像手指。左上角正是状态栏，人点不到那里；
///    真实点击的落点是 (891.5, 61.0) 这种坐标。所以这里自己接遮罩的点击，
///    把没有坐标的事件丢掉，其余照常关闭。
class AddSheetRoute extends ModalBottomSheetRoute<String> {
  AddSheetRoute({
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.showDragHandle,
    super.isDismissible,
    super.enableDrag,
    super.modalBarrierColor,
  });

  /// 幽灵触点的落点。
  ///
  /// 判据是**恰好等于原点**，不是「离原点很近」：真的点左上角也不该关菜单，
  /// 那里是状态栏。
  static const Offset _ghostOrigin = Offset.zero;

  /// 幽灵触点的判据坐标，测试用。
  @visibleForTesting
  static Offset get ghostOriginForTest => _ghostOrigin;

  @override
  Widget buildModalBarrier() {
    if (barrierColor.a == 0 || offstage) {
      // 没有遮罩色就没有可点的一片区域，交回框架（它只放一个空壳）。
      return super.buildModalBarrier();
    }
    final Animation<Color?> color = animation!.drive(
      ColorTween(
        begin: barrierColor.withValues(alpha: 0),
        end: barrierColor,
      ).chain(CurveTween(curve: barrierCurve)),
    );
    void dismiss() {
      if (barrierDismissible) {
        navigator?.maybePop();
      }
    }

    return AnimatedBuilder(
      animation: color,
      builder: (context, _) => Semantics(
        // 框架的 ModalBarrier 会把这层标成「按钮」，读屏用户能靠它知道
        // 「外面这一圈是可以点掉菜单的」。以前这里只有一个 onTap，读屏
        // 报出来的是「未标记」的一段区域，VoiceOver / TalkBack 走不到。
        label: barrierLabel,
        button: true,
        enabled: barrierDismissible,
        onTapHint: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        onTap: dismiss,
        child: GestureDetector(
          // 半透明的一层必须自己吃掉点击，否则会穿透到底下的列表。
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            trace('barrier tap ${details.globalPosition.dx.toStringAsFixed(1)},'
                '${details.globalPosition.dy.toStringAsFixed(1)}');
            if (details.globalPosition == _ghostOrigin) {
              trace('barrier tap at the origin -> ghost pointer, ignored');
              return;
            }
            dismiss();
          },
          child: ColoredBox(color: color.value ?? Colors.transparent),
        ),
      ),
    );
  }
}
