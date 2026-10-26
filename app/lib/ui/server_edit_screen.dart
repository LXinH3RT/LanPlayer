import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../data/lan_scan.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/stores.dart';

/// 手工填写 SMB 服务器；「测试连接」会真的跑一次内核的 probe，
/// 而不是假装成功。
///
/// 「扫描局域网」是可选的一步：并发探测本机所在 /24 的 445 端口，
/// 把开放的主机列出来，点一下就自动填进「IP 地址」。
/// 只填地址，共享名仍要用户自己填（有意不做共享名枚举，见 docs/roadmap.md）。
class ServerEditScreen extends StatefulWidget {
  const ServerEditScreen({super.key, this.profile, this.autoScan = false});

  final ServerProfile? profile;

  /// 进入页面后自动跑一次局域网扫描。只给桌面端的自动化验证用
  /// （`LANPLAYER_UI=add-server LANPLAYER_AUTOSCAN=1`），正常使用保持 false。
  final bool autoScan;

  @override
  State<ServerEditScreen> createState() => _ServerEditScreenState();
}

class _ServerEditScreenState extends State<ServerEditScreen> {
  final _form = GlobalKey<FormState>();

  /// 懒加载：添加服务器页本身不需要原生内核就能渲染（扫描局域网是纯 Dart），
  /// 只有真的点「测试连接」时才去 open lanplayer.dll。
  /// 这样即便内核库缺失，页面也能打开并填完再报错，而不是整页打不开。
  late final MediaRepository _repo = MediaRepository();

  late final TextEditingController _host =
      TextEditingController(text: widget.profile?.host ?? '192.168.1.');
  late final TextEditingController _port =
      TextEditingController(text: '${widget.profile?.port ?? 445}');
  late final TextEditingController _share =
      TextEditingController(text: widget.profile?.share ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.profile?.user ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.profile?.password ?? '');

  bool _busy = false;
  bool _obscure = true;
  String? _status;

  /// 扫描状态：null 表示没扫过；扫完是候选列表（可能为空）。
  bool _scanning = false;
  List<LanHost>? _scanned;
  int _scanDone = 0;
  int _scanTotal = 0;

  @override
  void initState() {
    super.initState();
    if (widget.autoScan) {
      // 等第一帧画完再扫，否则 _busy 的 setState 会在 build 过程中触发。
      WidgetsBinding.instance.addPostFrameCallback((_) => _scanLan());
    }
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _share, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 扫本机所在网段的 445 端口。这是「减少手输」的可选步骤，
  /// 失败也只提示，不阻塞手工填写。
  Future<void> _scanLan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanned = null;
      _scanDone = 0;
      _scanTotal = 0;
      _status = null;
    });
    try {
      final subnets = await localSubnets();
      if (subnets.isEmpty) {
        if (mounted) {
          setState(() {
            _scanning = false;
            _status = '没找到本机的局域网网段，请手工填写地址';
          });
        }
        return;
      }
      final hosts = await scanSubnet(
        subnets.first,
        onProgress: (done, total) {
          if (!mounted) return;
          // 每 16 个地址刷一次，避免 254 次 setState 把界面刷爆。
          if (done == total || done % 16 == 0) {
            setState(() {
              _scanDone = done;
              _scanTotal = total;
            });
          }
        },
      );
      // 反查主机名是锦上添花，超时就直接显示 IP，不能拖住界面。
      await resolveNames(hosts, timeout: const Duration(milliseconds: 800));
      // 扫描结果打进日志，方便在没人看屏幕的时候验证（自动化用）。
      for (final host in hosts) {
        // ignore: avoid_print
        print('LanPlayer lan host: ${host.address} name=${host.name ?? "-"}');
      }
      // ignore: avoid_print
      print('LanPlayer lan scan: ${subnets.first} -> ${hosts.length} hosts');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanned = hosts;
        if (hosts.isEmpty) {
          // iOS / Android 在拒绝「本地网络」权限时，连接是静默失败的，
          // 扫出来就是 0 台 —— 看起来跟「网段里真没有服务器」一样。
          // 这里把两种可能都提示出来，免得用户以为软件坏了。
          _status = Platform.isIOS || Platform.isAndroid
              ? '这个网段没有开放 445 端口的主机；'
                  '如果你确定有服务器，请到「设置」里允许 LanPlayer 访问本地网络'
              : '这个网段没有开放 445 端口的主机';
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _status = '扫描失败：$e';
      });
    }
  }

  void _pickHost(LanHost host) {
    setState(() {
      _host.text = host.address;
    });
  }

  /// 卡片标题直接用共享名。
  ///
  /// 原来这里是一个「显示名称（可选）」输入框，留空时也回退到共享名 —— 也就是说
  /// 它唯一的用途是让同一个共享在两个名字之间切换（比如两台机器都有 Movies）。
  /// 实际用下来这一步没人填，反而每次添加都要多看一个空框，所以去掉：
  /// 显示名恒等于共享名，[ServerProfile.name] 字段本身保留，老配置照旧能读。
  ServerProfile _build() => ServerProfile(
        id: widget.profile?.id ??
            'srv-${DateTime.now().millisecondsSinceEpoch}',
        name: _share.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 445,
        share: _share.text.trim(),
        user: _user.text.trim(),
        password: _password.text,
        createdAt: widget.profile?.createdAt,
      );

  Future<bool> _test() async {
    if (!(_form.currentState?.validate() ?? false)) return false;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await _repo.probeServer(_build());
      if (!mounted) return true;
      setState(() => _status = '连接成功');
      return true;
    } on MediaSourceException catch (e) {
      if (mounted) setState(() => _status = e.message);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final ok = await _test();
    if (!ok) return;
    await ServerStore.instance.upsert(_build());
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text(widget.profile == null ? '添加服务器' : '编辑服务器')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: 'IP 地址或主机名',
                      hintText: '192.168.1.10',
                      border: OutlineInputBorder(),
                    ),
                    autocorrect: false,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写服务器地址' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final p = int.tryParse(v ?? '');
                      return (p == null || p <= 0 || p > 65535) ? '端口无效' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // 扫描局域网：可选，只填地址，共享名仍由用户填。
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scanLan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar, size: 18),
                  label:
                      Text(_scanning ? '正在扫描 $_scanDone/$_scanTotal' : '扫描局域网'),
                ),
                const SizedBox(width: 10),
                if (_scanned != null && !_scanning)
                  Text(
                    '找到 ${_scanned!.length} 台',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            if (_scanned != null && _scanned!.isNotEmpty) ...[
              const SizedBox(height: 10),
              LanHostPicker(
                hosts: _scanned!,
                selected: _host.text.trim(),
                onPick: _pickHost,
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: _share,
              decoration: const InputDecoration(
                labelText: '共享名',
                hintText: 'Movies（Windows 上右键共享时的名称）',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写共享名' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(
                labelText: '用户名',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              autofillHints: const [AutofillHints.username],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon:
                      Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
              autofillHints: const [AutofillHints.password],
            ),
            if (_status != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    _status!.contains('成功')
                        ? Icons.check_circle
                        : Icons.error_outline,
                    size: 18,
                    color: _status!.contains('成功')
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child:
                          Text(_status!, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.network_check),
              label: const Text('测试连接'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
            const SizedBox(height: 16),
            Text(
              '提示：共享名就是 Windows 上「属性 → 共享」里填的名字。'
              '点"测试连接"会真的连一次服务器来验证账号密码。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 扫描结果列表：每行一台主机，点一下回调 [onPick]。
///
/// 单独抽出来是为了能在 widget 测试里断言「结果真的被渲染出来」，
/// 而不是只断言扫描函数返回了正确的列表。
class LanHostPicker extends StatelessWidget {
  const LanHostPicker({
    super.key,
    required this.hosts,
    required this.selected,
    required this.onPick,
  });

  final List<LanHost> hosts;

  /// 当前地址框里的值；与某一行相同时该行右侧显示对勾。
  final String selected;

  final ValueChanged<LanHost> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final host in hosts)
            InkWell(
              onTap: () => onPick(host),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.dns_outlined, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(host.label)),
                    if (host.address == selected)
                      Icon(
                        Icons.check,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          Text(
            '点一行就填进上面的地址框；共享名仍需自己填',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
