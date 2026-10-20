import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../data/stores.dart';

/// 手工填写 SMB 服务器；「测试连接」会真的跑一次内核的 probe，
/// 而不是假装成功。
class ServerEditScreen extends StatefulWidget {
  const ServerEditScreen({super.key, this.profile});

  final ServerProfile? profile;

  @override
  State<ServerEditScreen> createState() => _ServerEditScreenState();
}

class _ServerEditScreenState extends State<ServerEditScreen> {
  final _form = GlobalKey<FormState>();
  final _repo = MediaRepository();

  late final TextEditingController _name =
      TextEditingController(text: widget.profile?.name ?? '');
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

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _share, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  ServerProfile _build() => ServerProfile(
        id: widget.profile?.id ??
            'srv-${DateTime.now().millisecondsSinceEpoch}',
        name:
            _name.text.trim().isEmpty ? _share.text.trim() : _name.text.trim(),
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
          AppBar(title: Text(widget.profile == null ? '添加 SMB 服务器' : '编辑服务器')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '显示名称（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
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
