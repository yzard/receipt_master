import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import 'app_theme.dart';

String itemDisplayName(String? productName, String? printedName, String kind) {
  final product = productName?.trim() ?? '';
  final printed = printedName?.trim() ?? '';
  return product.isNotEmpty
      ? product
      : printed.isNotEmpty
      ? printed
      : kindLabels[kind]!;
}

class ReceiptItemName extends StatelessWidget {
  final String? productName;
  final String printedName, kind;
  const ReceiptItemName({
    super.key,
    required this.productName,
    required this.printedName,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    final name = itemDisplayName(productName, printedName, kind);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: Text(name)),
        if (printedName.trim().isNotEmpty && printedName.trim() != name) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              printedName,
              style: TextStyle(fontSize: 12, color: AppPalette.muted(context)),
            ),
          ),
        ],
      ],
    );
  }
}

String dateText(int utc, String zone) => DateFormat('yyyy-MM-dd HH:mm').format(
  tz.TZDateTime.from(
    DateTime.fromMillisecondsSinceEpoch(utc, isUtc: true),
    tz.getLocation(zone),
  ),
);
void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  final text = error is InputError
      ? error.message
      : '操作失败，请检查输入或重试。${error.runtimeType}';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      showCloseIcon: true,
      duration: const Duration(seconds: 6),
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askText(
  BuildContext context,
  String title,
  String initial,
  String hint,
) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(helperText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  // The route can still be animating out; the controller is owned by that completed dialog.
  return result;
}

Future<String?> chooseCategory(
  BuildContext context,
  List<Map<String, dynamic>> categories,
  String current,
) async => showDialog<String>(
  context: context,
  builder: (ctx) => SimpleDialog(
    title: const Text('选择商品分类'),
    children: categories
        .map(
          (c) => ListTile(
            title: Text(c['path']),
            leading: Icon(
              c['category_id'] == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            onTap: () => Navigator.pop(ctx, c['category_id']),
          ),
        )
        .toList(),
  ),
);

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, detail;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppPalette.muted(context), height: 1.6),
          ),
        ],
      ),
    ),
  );
}

class Notice extends StatelessWidget {
  final String text;
  const Notice(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      color: AppPalette.warningSurface(context),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
