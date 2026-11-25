import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../l10n/strings.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import 'app_theme.dart';

String itemDisplayName(
  BuildContext context,
  String? productName,
  String? printedName,
  String kind,
) {
  final product = productName?.trim() ?? '';
  final printed = printedName?.trim() ?? '';
  return product.isNotEmpty
      ? product
      : printed.isNotEmpty
      ? printed
      : context.tr(kindLabels[kind]!);
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
    final name = itemDisplayName(context, productName, printedName, kind);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Text(name, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (printedName.trim().isNotEmpty && printedName.trim() != name) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              printedName,
              style: TextStyle(fontSize: 12, color: context.tokens.text3),
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
  final text = error is TimeoutException
      ? 'Timeout'
      : error is SocketException || error is http.ClientException
      ? context.tr('网络不可用，显示缓存')
      : error is InputError
      ? context.translatedMessage(error.message)
      : context.tr("操作失败，请检查输入或重试。{0}", [error.runtimeType]);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      showCloseIcon: true,
      duration: const Duration(seconds: 6),
    ),
  );
}

Future<T?> openPageOverlay<T>(BuildContext context, Widget page) =>
    showDialog<T>(
      context: context,
      useSafeArea: false,
      barrierDismissible: false,
      builder: (_) => Dialog.fullscreen(child: page),
    );

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr("取消")),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr("确认")),
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
          child: Text(context.tr("取消")),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(context.tr("确定")),
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
    title: Text(context.tr("选择商品分类")),
    children: categories
        .map(
          (c) => ListTile(
            title: Text(c['path']),
            leading: Icon(
              c['category_id'] == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: c['category_id'] == current
                  ? Theme.of(ctx).colorScheme.primary
                  : null,
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
      padding: const EdgeInsets.all(Space.x4l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            foregroundColor: AppPalette.muted(context),
            child: Icon(icon, size: 28),
          ),
          const SizedBox(height: Space.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppPalette.muted(context), height: 1.5),
          ),
        ],
      ),
    ),
  );
}

enum NoticeTone {
  warning,
  error,
  info,
  success;

  (Color, Color, Color, IconData) _appearance(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    return switch (this) {
      warning => (
        tokens.warning,
        tokens.warningSoft,
        tokens.warningBorder,
        Icons.warning_amber_rounded,
      ),
      error => (
        scheme.error,
        scheme.errorContainer,
        tokens.dangerBorder,
        Icons.error_outline,
      ),
      info => (
        tokens.info,
        tokens.infoSoft,
        Colors.transparent,
        Icons.info_outline,
      ),
      success => (
        tokens.success,
        tokens.successSoft,
        Colors.transparent,
        Icons.check_circle_outline,
      ),
    };
  }
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.tone = NoticeTone.warning});

  final String text;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, border, icon) = tone._appearance(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      margin: const EdgeInsets.symmetric(vertical: Space.sm),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: Space.sm),
          Expanded(child: Text(context.translatedMessage(text))),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.tone});

  final String label;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, _, _) = tone._appearance(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: foreground,
              shape: BoxShape.circle,
            ),
            child: const SizedBox.square(dimension: 6),
          ),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
