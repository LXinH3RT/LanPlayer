import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/home_sources.dart';

/// 一块来源「上次连过没有」的结论。
///
/// 用户报的现象：服务器不在线时点「全部」，要干等十几秒才弹「出错了」——
/// 因为那颗按钮每次都先真的去连一遍，等到 socket 超时才失败。而他看到的
/// 那块来源上早就写着「连不上」了。
///
/// 所以把「连过没有」这件事本身记下来：启动、刷新、重试会去连并把结论写在
/// 这里；进目录、点「全部」这类**顺着已有结论走**的动作先读这里，判定为
/// 离线就直接给提示，不再去等一次超时。
///
/// 只记内存，不落盘：进程重启时网络状况可能已经变了，把一个上次会话的
/// 「离线」带到下一次启动，等于把用户锁在离线状态里。
class SourceHealth extends ChangeNotifier {
  static final SourceHealth instance = SourceHealth();

  final Map<String, String> _offline = {};

  /// 这块来源上次连接失败时的说明；连上过就是 null。
  String? offlineReason(String sourceId) => _offline[sourceId];

  bool isOffline(String sourceId) => _offline.containsKey(sourceId);

  /// 连接成功（或者压根没连过）时清掉离线标记。
  void markOnline(String sourceId) {
    if (_offline.remove(sourceId) != null) notifyListeners();
  }

  /// 连接失败：记下原因，界面据此把那一块标成离线。
  void markOffline(String sourceId, String reason) {
    if (_offline[sourceId] == reason) return;
    _offline[sourceId] = reason;
    notifyListeners();
  }

  /// 只清一块（来源被删掉时）。
  void forget(String sourceId) {
    if (_offline.remove(sourceId) != null) notifyListeners();
  }

  @visibleForTesting
  void debugReset() => _offline.clear();
}

/// 离线时给用户的统一说法。
///
/// 用户要求提示里带上「请重新连接服务器或刷新后重试」—— 只说「超时」的话，
/// 用户不知道下一步该干什么，只会反复点同一个按钮再等十几秒。
String offlineHint(String url, String? reason) {
  final head = reason == null || reason.isEmpty
      ? '无法访问 $url：连接超时或服务器不可达'
      : reason;
  return '$head\n\n请重新连接服务器或刷新后重试。';
}

/// 这块来源是不是已知连不上。
///
/// 单独抽出来是为了让首页与浏览页用同一条判断 —— 两处口径不一致会出现
/// 「首页说离线、点进去又等二十秒」这种事。
bool sourceIsOffline(HomeSource source, SourceHealth health) =>
    health.isOffline(source.id);
