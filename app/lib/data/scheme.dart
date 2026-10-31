/// URL scheme 在 Dart 侧的唯一定义处。
///
/// 以前 `smb://` 与 `file://` 这两个字面量散在七个文件里（models、location、
/// repository、folders、progress、main、folder_picker），内核那边每加一种源类型，
/// Dart 侧都要把这些地方挨个改一遍，漏掉一处就会拼出打不开的 URL。现在只在这里
/// 写一次；内核侧同一份信息在 `native/source/source_internal.h` 的传输层注册表
/// 与 `native/sources.cmake` 的清单里，两边靠 `tool/check_all.py` 的一致性检查
/// 对齐。
abstract final class LpScheme {
  /// Windows 共享（内核里由 libsmb2 实现）。
  static const String smb = 'smb';

  /// 本机文件（内核里直接走文件 API）。
  static const String file = 'file';

  /// SMB 的默认端口。写成默认值时代省略，和内核 `LpTransport.default_port` 一致。
  static const int smbDefaultPort = 445;

  /// `<scheme>://` 前缀。
  static const String smbPrefix = 'smb://';
  static const String filePrefix = 'file://';

  /// `smb://host/share`，端口不是 445 时补上。
  static String smbRoot(String host, int port, String share) =>
      '$smbPrefix$host${port == smbDefaultPort ? '' : ':$port'}/$share';

  /// `smb://user:pass@host/share`，账号密码按 URI 组件转义。
  static String smbRootWithCredentials(
    String host,
    int port,
    String share, {
    required String user,
    required String password,
  }) {
    final encodedUser = Uri.encodeComponent(user);
    final encodedPass = Uri.encodeComponent(password);
    return '$smbPrefix$encodedUser:$encodedPass@'
        '${host}${port == smbDefaultPort ? '' : ':$port'}/$share';
  }

  /// `file://<path>`，裸路径原样接在后面（本机路径不转义）。
  static String fileUrl(String path) => '$filePrefix$path';

  static bool isSmbUrl(String url) => url.startsWith(smbPrefix);

  static bool isFileUrl(String url) => url.startsWith(filePrefix);
}
