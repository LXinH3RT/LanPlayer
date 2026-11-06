import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 服务器密码的保管处。
///
/// 以前 [ServerProfile.password] 和服务器列表一起明文写在 `servers.json`
/// 里：那个文件在桌面端就是 `~/Library/Application Support/lanplayer/` 或
/// `%APPDATA%\lanplayer\` 下一个普通 JSON，任何能读用户目录的程序都能拿到
/// 局域网共享的账号密码。现在密码单独存进系统凭据库 —— iOS/macOS 是
/// Keychain，Android 是 KeyStore 包着的加密偏好，Windows 是凭据管理器 ——
/// 配置文件里只剩一个 id。
///
/// 这里刻意保留一条 CPU 兜底：凭据库在某些环境下不可用（最典型的是 Linux
/// 缺 libsecret，或者单元测试里插件没注册）。那时 [available] 变成 false，
/// [ServerStore] 退回把密码写在 JSON 里，功能不受影响 —— 悄悄丢密码比留一
/// 个明文文件更糟，用户会以为是他自己填错了。
class SecretStore {
  SecretStore._();

  static final SecretStore instance = SecretStore._();

  /// `first_unlock` 而不是默认的 `unlocked`：桌面端会在锁屏后继续跑（音量、
  /// 定时任务），此时读 `unlocked` 保护的条目会失败。`first_unlock` 表示开机
  /// 首次解锁之后就可读，仍是设备级加密。
  ///
  /// macOS 关掉 `usesDataProtectionKeychain`：那是 iOS 形态的钥匙串，要求 App
  /// 带 `keychain-access-groups` 权限（只有配了描述文件的签名才有），本地
  /// ad-hoc 签名或开发机签名会直接 `errSecMissingEntitlement`。用文件型登录
  /// 钥匙串对任何签名都成立。
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'lanplayer'),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock,
      usesDataProtectionKeychain: false,
    ),
  );

  static String _key(String id) => 'smb.password.$id';

  bool _unavailable = false;

  /// 凭据库是否可用。一旦某次读写抛出平台异常就永久置 false，后续调用直接
  /// 走兜底，不再反复重试（每次重试都会在日志里堆一条异常）。
  bool get available => !_unavailable;

  @visibleForTesting
  void debugResetAvailability() => _unavailable = false;

  /// 读出密码。没有存过（或凭据库不可用）时返回 null。
  Future<String?> read(String id) async {
    if (_unavailable || id.isEmpty) return null;
    try {
      return await _storage.read(key: _key(id));
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }

  /// 写入密码。空密码等于删除，避免在凭据库里留一条无意义记录。
  Future<void> write(String id, String password) async {
    if (_unavailable || id.isEmpty) return;
    try {
      if (password.isEmpty) {
        await _storage.delete(key: _key(id));
      } else {
        await _storage.write(key: _key(id), value: password);
      }
    } catch (e) {
      _markUnavailable(e);
    }
  }

  Future<void> delete(String id) async {
    if (_unavailable || id.isEmpty) return;
    try {
      await _storage.delete(key: _key(id));
    } catch (e) {
      _markUnavailable(e);
    }
  }

  void _markUnavailable(Object e) {
    if (_unavailable) return;
    _unavailable = true;
    // 只打一次：调用点可能是每次进首页的 load()，重复打印会把日志淹掉。
    debugPrint('LanPlayer: secure storage unavailable ($e); '
        'SMB passwords fall back to the profile file');
  }
}
