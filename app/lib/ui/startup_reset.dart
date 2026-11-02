import 'package:flutter/widgets.dart';

/// 冷启动时把导航栈收回到首页，返回弹掉的层数。
///
/// 为什么需要在 Dart 侧兜一道：移动端有两种「进程重建时把上次界面带回来」的
/// 机制，都不在这个仓库的代码里 ——
///
/// - Android：`FlutterActivity` 默认把 InstanceState 交给引擎，引擎连导航栈
///   一起恢复。从最近任务里划掉卡片再点图标，就可能直接落回上次的播放页。
/// - iPadOS：窗口会话恢复允许系统把上一次的控制器层级带回来。
///
/// 这个应用不需要这种恢复：上次看到哪儿已经由 `ProgressStore` 记住，首页那
/// 一行会显示「已看 xx%」。而把播放页恢复回来是有代价的 —— 那个 SMB 源这时
/// 往往已经不可达（换了网、服务器没开），用户看到的是一句「连接失败」，还得
/// 先按返回键才能回首页。
///
/// 所以启动流程在跑完验证钩子之前先把栈收到只剩根路由。正常启动时栈里本来
/// 就只有首页，这里是空操作。
int collapseToHome(NavigatorState navigator) {
  var popped = 0;
  navigator.popUntil((Route<dynamic> route) {
    final isFirst = route.isFirst;
    if (!isFirst) popped += 1;
    return isFirst;
  });
  return popped;
}
