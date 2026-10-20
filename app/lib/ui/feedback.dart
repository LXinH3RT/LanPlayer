import 'package:flutter/material.dart';

import '../data/models.dart';

Future<void> showError(BuildContext context, String message) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('出错了'),
      content: SelectableText(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
      ],
    ),
  );
}

void showSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Secondary line of a server card: root URL plus how it authenticates.
String describeServer(ServerProfile p) {
  final parts = <String>[p.rootUrl];
  if (p.user.isNotEmpty) parts.add('用户 ${p.user}');
  return parts.join('  ·  ');
}
