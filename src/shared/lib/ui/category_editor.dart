import '../l10n/strings.dart';

import 'package:flutter/material.dart';

import '../data/store.dart';
import 'catalog_search.dart';

class CategoryEditorDialog extends StatefulWidget {
  const CategoryEditorDialog({
    super.key,
    required this.store,
    required this.category,
    required this.categories,
  });
  final AppStore store;
  final Map<String, dynamic>? category;
  final List<Map<String, dynamic>> categories;
  @override
  State<CategoryEditorDialog> createState() => _CategoryEditorDialogState();
}

class _CategoryEditorDialogState extends State<CategoryEditorDialog> {
  late final TextEditingController name;
  String? parent, error;
  bool submitting = false;
  final excluded = <String>{};

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.category?['name'] ?? '');
    parent = widget.category?['parent_id'];
    if (widget.category != null) excluded.add(widget.category!['category_id']);
    bool changed = true;
    while (changed) {
      changed = false;
      for (final c in widget.categories) {
        if (excluded.contains(c['parent_id']) &&
            excluded.add(c['category_id'])) {
          changed = true;
        }
      }
    }
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = name.text;
    if (value.trim().isEmpty ||
        widget.categories.any(
          (c) =>
              c['category_id'] != widget.category?['category_id'] &&
              catalogNameKey(c['name']) == catalogNameKey(value),
        )) {
      setState(
        () => error = value.trim().isEmpty ? '请输入商品种类名称' : '商品种类名称已存在，请使用其他名称',
      );
      return;
    }
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await widget.store.saveCategory(
        widget.category?['category_id'],
        value,
        parent,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          submitting = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.category == null ? context.tr("添加商品种类") : context.tr("编辑商品种类"),
    ),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CatalogSearchField(
          store: widget.store,
          component: 'categories',
          controller: name,
          label: context.tr("商品种类"),
          enabled: !submitting,
          rejectExistingName: true,
          currentId: widget.category?['category_id'],
          onChanged: (_) => setState(() => error = null),
          onSelected: (_) => setState(() => error = null),
        ),
        if (error != null)
          Text(
            context.translatedMessage(error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        DropdownButtonFormField<String>(
          initialValue: parent ?? '',
          decoration: InputDecoration(labelText: context.tr("父类")),
          items: [
            DropdownMenuItem(value: '', child: Text(context.tr("顶层"))),
            for (final c in widget.categories)
              if (!excluded.contains(c['category_id']))
                DropdownMenuItem(
                  value: c['category_id'],
                  child: Text(c['path']),
                ),
          ],
          onChanged: submitting
              ? null
              : (v) => setState(() => parent = v == '' ? null : v),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: submitting ? null : () => Navigator.pop(context),
        child: Text(context.tr("取消")),
      ),
      TextButton(
        onPressed: submitting ? null : save,
        child: Text(context.tr("保存")),
      ),
    ],
  );
}
