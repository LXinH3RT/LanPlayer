import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/secret_store.dart';
import 'package:lanplayer/data/stores.dart';

/// 密码保管的三条路径：进凭据库、从凭据库读回、以及凭据库不可用时的兜底。
///
/// 用插件自带的 [TestFlutterSecureStoragePlatform] 顶掉平台实现 —— 真正的
/// Keychain / KeyStore 在单元测试里不存在，直接调会抛
/// `MissingPluginException`。
void main() {
  late Directory dir;
  late Map<String, String> vault;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lp_secret_');
    AppStorage.directoryOverride = dir;
    AppStorage.debugResetDirectory();
    vault = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(vault);
    SecretStore.instance.debugResetAvailability();
    ServerStore.instance.debugReset();
  });

  tearDown(() async {
    AppStorage.directoryOverride = null;
    AppStorage.debugResetDirectory();
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
    SecretStore.instance.debugResetAvailability();
    ServerStore.instance.debugReset();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  ServerProfile profile({String id = 'srv-1', String password = 'hunter2'}) =>
      ServerProfile(
        id: id,
        name: 'share',
        host: '192.168.1.10',
        share: 'share',
        user: 'gongxiang',
        password: password,
      );

  test('password goes to the vault, servers.json keeps no password field',
      () async {
    await ServerStore.instance.upsert(profile());

    expect(vault['smb.password.srv-1'], 'hunter2');

    final raw = File('${dir.path}/servers.json').readAsStringSync();
    expect(raw.contains('hunter2'), isFalse);
    expect(raw.contains('"password"'), isFalse);
    // 其余字段照旧，别把整条记录写丢。
    expect(raw.contains('192.168.1.10'), isTrue);
    expect(raw.contains('gongxiang'), isTrue);
  });

  test('a restart reads the password back from the vault', () async {
    await ServerStore.instance.upsert(profile());
    ServerStore.instance.debugReset();

    await ServerStore.instance.load();

    expect(ServerStore.instance.servers, hasLength(1));
    expect(ServerStore.instance.servers.single.password, 'hunter2');
  });

  test('a plaintext password in the old file is moved into the vault',
      () async {
    // 模拟旧版本留下的 servers.json：密码和别的字段挤在同一条记录里。
    final legacy = StringBuffer()
      ..write('{"version":1,"servers":[{"id":"srv-old","name":"old",')
      ..write('"host":"192.168.1.9","port":445,"share":"share",')
      ..write('"user":"u","password":"legacy-pass",')
      ..write('"createdAt":1700000000000}]}');
    File('${dir.path}/servers.json').writeAsStringSync(legacy.toString());

    await ServerStore.instance.load();

    expect(vault['smb.password.srv-old'], 'legacy-pass');
    final raw = File('${dir.path}/servers.json').readAsStringSync();
    expect(raw.contains('legacy-pass'), isFalse,
        reason: '迁移之后文件里不该再留明文');

    // 第二次启动走的是凭据库这条路。
    ServerStore.instance.debugReset();
    await ServerStore.instance.load();
    expect(ServerStore.instance.servers.single.password, 'legacy-pass');
  });

  test('removing a server removes its stored secret too', () async {
    await ServerStore.instance.upsert(profile());
    expect(vault, isNotEmpty);

    await ServerStore.instance.remove('srv-1');

    expect(vault.containsKey('smb.password.srv-1'), isFalse);
  });

  test('an empty password deletes the entry instead of storing blank',
      () async {
    await ServerStore.instance.upsert(profile());
    expect(vault.containsKey('smb.password.srv-1'), isTrue);

    await ServerStore.instance.upsert(profile(password: ''));

    expect(vault.containsKey('smb.password.srv-1'), isFalse);
  });

  test('without a vault the password falls back to the file, not into thin air',
      () async {
    // 让平台实现抛异常，模拟缺 libsecret / 插件未注册。
    FlutterSecureStoragePlatform.instance = _BrokenPlatform();

    await ServerStore.instance.upsert(profile(password: 'fallback-pw'));

    expect(SecretStore.instance.available, isFalse);
    final raw = File('${dir.path}/servers.json').readAsStringSync();
    expect(raw.contains('fallback-pw'), isTrue,
        reason: '凭据库写不进去时必须留在文件里，否则用户会以为账号有问题');

    // 读回来也还在。
    ServerStore.instance.debugReset();
    await ServerStore.instance.load();
    expect(ServerStore.instance.servers.single.password, 'fallback-pw');
  });
}

/// 任何调用都失败的平台实现。
class _BrokenPlatform extends FlutterSecureStoragePlatform {
  Never _fail() => throw MissingPluginException('no keychain');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      _fail();

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      _fail();

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _fail();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      _fail();

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      _fail();

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      _fail();
}
