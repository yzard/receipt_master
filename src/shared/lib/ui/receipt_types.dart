import 'package:flutter/material.dart';

import '../data/store.dart';
import 'common.dart';

class ReceiptTypesManager extends StatefulWidget {
  final AppStore store;
  const ReceiptTypesManager({super.key, required this.store});
  @override
  State<ReceiptTypesManager> createState() => _ReceiptTypesManagerState();
}

class _ReceiptTypesManagerState extends State<ReceiptTypesManager> {
  List<Map<String, dynamic>> types = [], merchants = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    run(() async {});
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      final t = await widget.store.receiptTypes();
      final m = await widget.store.merchants();
      if (mounted) {
        setState(() {
          types = t;
          merchants = m;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit(Map<String, dynamic>? type) async {
    final controller = TextEditingController(text: type?['name'] ?? '');
    String? message;
    bool saving = false;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(type == null ? '添加商店类别' : '编辑商店类别'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '商店类别名称',
                  errorText: message,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (saving) return;
                      update(() => saving = true);
                      try {
                        await widget.store.saveReceiptType(
                          type?['receipt_type_id'],
                          controller.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (ctx.mounted) update(() => message = e.toString());
                      } finally {
                        if (ctx.mounted) update(() => saving = false);
                      }
                    },
              child: const Text('保存类别'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (mounted) await run(() async {});
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('商店类别与商品种类独立。商店类别用于新识别收据，修改商店不会改变历史消费。'),
      if (busy) const LinearProgressIndicator(),
      if (error != null) Notice(error!),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in types)
            InputChip(
              label: Text(t['name']),
              onPressed: busy || t['system_key'] != null ? null : () => edit(t),
              onDeleted: busy || t['system_key'] != null
                  ? null
                  : () async {
                      if (await confirm(
                        context,
                        '删除商店类别',
                        '保留所有收据，关联消费和商店变为未分类。',
                      )) {
                        await run(
                          () => widget.store.deleteReceiptType(
                            t['receipt_type_id'],
                          ),
                        );
                      }
                    },
            ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: busy ? null : () => edit(null),
          icon: const Icon(Icons.add),
          label: const Text('添加商店类别'),
        ),
      ),
      const SizedBox(height: 16),
      Text('商店类别设置', style: Theme.of(context).textTheme.titleMedium),
      for (final m in merchants)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(m['name'])),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('${m['merchant_id']}-${m['receipt_type_id']}'),
                  initialValue: m['receipt_type_id'],
                  decoration: const InputDecoration(labelText: '商店类别'),
                  items: [
                    for (final t in types)
                      DropdownMenuItem(
                        value: t['receipt_type_id'] as String,
                        child: Text(t['name']),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) {
                            run(
                              () => widget.store.classifyMerchant(
                                m['merchant_id'],
                                value,
                              ),
                            );
                          }
                        },
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
