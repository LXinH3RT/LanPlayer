import 'package:flutter/material.dart';

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
