/// 软件的版本号，构建时由脚本从 `app/pubspec.yaml` 读出来注入。
///
/// pubspec 是版本的唯一来源，Flutter 本身不会把它带进代码里：`flutter build`
/// 只把 Dart 编成 kernel，Dart 读不到 `package_info`。所以三个构建脚本
/// （`scripts/build_windows_desktop.py`、`scripts/build_macos_dmg.py`、
/// `scripts/build_android_apk.py`）都会调 `lp.pubspec_version()` 取出 `x.y.z`，
/// 再用 `--dart-define=LANPLAYER_VERSION=` 传进来。
///
/// 直接 `flutter run` 或跑测试时没有这个 define，落回 `dev`。
library;

const String kAppVersion = String.fromEnvironment(
  'LANPLAYER_VERSION',
  defaultValue: 'dev',
);
