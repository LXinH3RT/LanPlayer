/// LanPlayer 的 C 内核在 Dart 侧的入口包。
///
/// 本包没有 Dart 实现代码：它存在的意义只有一条——让 Flutter 在 iOS / macOS
/// 构建时把 `ios/lanplayer_core.podspec` 或 `macos/lanplayer_core.podspec`
/// 交给 CocoaPods，从而把 `native/` 编出来的静态库链进 Runner。
///
/// 真正的 FFI 绑定在 `app/lib/core/bindings.dart` 里（`NativeCore` 类）。那里面
/// 在 iOS / macOS 上用的是 `DynamicLibrary.process()`，也就是从 app 主二进制里
/// 找 `lp_*` 符号——所以内核必须是静态链入的，不能是 dylib。
///
/// 这里只放一个常量，方便排查问题时确认版本。
library;

/// 内核静态库的版本号，与 podspec 里的 `s.version` 保持一致。
const String lanplayerCoreVersion = '0.1.0';
