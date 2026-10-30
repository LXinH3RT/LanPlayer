import 'dart:io' show Platform;

/// 验证用的编译期开关。
///
/// 桌面端（Windows / macOS）直接从进程环境变量取；iOS / Android 上
/// `Platform.environment` 永远是空表（app 由系统 launchd 拉起，Dart 拿不到
/// `environ`），所以再退一步查编译期 `--dart-define`。两者都支持，方便同一套
/// 脚本在三个平台跑。
///
/// 移动端没有输入注入手段 —— `devicectl` 只能截图和启停进程，`adb` 的
/// `input tap` 也依赖坐标而不是控件 —— 所以「进某个页面」「滚到底部」这类动作
/// 只能靠开关自己走一遍，否则真机上留不下证据。
///
/// **新增开关时两边都要加**：这里的环境变量分支与编译期分支。Dart 的
/// `String.fromEnvironment` 只认字面量名字，没法按变量查表。
String? probeFlag(String name) {
  final fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  switch (name) {
    case 'LANPLAYER_OPEN':
      const v = String.fromEnvironment('LANPLAYER_OPEN');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_STATE_DIR':
      const v = String.fromEnvironment('LANPLAYER_STATE_DIR');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_BROWSE':
      const v = String.fromEnvironment('LANPLAYER_BROWSE');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_USER':
      const v = String.fromEnvironment('LANPLAYER_USER');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_PASS':
      const v = String.fromEnvironment('LANPLAYER_PASS');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_UI':
      const v = String.fromEnvironment('LANPLAYER_UI');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_AUTOSCAN':
      const v = String.fromEnvironment('LANPLAYER_AUTOSCAN');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_SETTINGS_SCROLL':
      const v = String.fromEnvironment('LANPLAYER_SETTINGS_SCROLL');
      return v.isEmpty ? null : v;
    case 'LANPLAYER_SETTINGS_TAB':
      const v = String.fromEnvironment('LANPLAYER_SETTINGS_TAB');
      return v.isEmpty ? null : v;
  }
  return null;
}
