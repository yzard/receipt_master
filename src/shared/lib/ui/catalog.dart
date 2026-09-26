import 'package:flutter/material.dart';

import '../data/store.dart';
import 'common.dart';
import 'logo_aliases.dart';
import 'product_receipts.dart';
import 'app_theme.dart';

class CatalogPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Future<void> Function(String) onReceipt;
  const CatalogPage({
    super.key,
    required this.store,
    required this.zone,
    required this.onReceipt,
  });
  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<Map<String, dynamic>> categories = [],
      printedNames = [],
      productNames = [];
  bool loading = true, saving = false;
  String? error;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      await widget.store.loadPreferences();
      final c = await widget.store.categories();
      final p = await widget.store.printedNames();
      final n = await widget.store.productNames();
      if (mounted) {
        setState(() {
          categories = c;
          printedNames = p;
          productNames = n;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> action(Future<void> Function() f) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await f();
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> editCategory(Map<String, dynamic>? category) async {
    final name = TextEditingController(text: category?['name'] ?? '');
    String? parent = category?['parent_id'];
    final excluded = <String>{if (category != null) category['category_id']};
    // Exclude the current category and its descendants from possible parents.
    bool changed = true;
    while (changed) {
      changed = false;
      for (final c in categories) {
        if (excluded.contains(c['parent_id']) &&
            excluded.add(c['category_id'])) {
          changed = true;
        }
      }
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(category == null ? '添加商品种类' : '编辑商品种类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '商品种类'),
              ),
              DropdownButtonFormField<String>(
                initialValue: parent ?? '',
                decoration: const InputDecoration(labelText: '父类'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('顶层')),
                  for (final c in categories)
                    if (!excluded.contains(c['category_id']))
                      DropdownMenuItem(
                        value: c['category_id'],
                        child: Text(c['path']),
                      ),
                ],
                onChanged: (v) =>
                    setDialogState(() => parent = v == '' ? null : v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final value = name.text;
    name.dispose();
    if (accepted == true) {
      await widget.store.saveCategory(category?['category_id'], value, parent);
    }
  }

  Future<void> removeName(Map<String, dynamic> n) async {
    if (!await confirm(
      context,
      '删除商品名称',
      '删除“${n['name']}”及其名称关联；保留所有收据和照片，相关商品恢复显示票面名称。',
    )) {
      return;
    }
    await widget.store.deleteProductName(n['product_name_id']);
  }

  Future<void> removeCategory(Map<String, dynamic> c) async {
    if (!await confirm(
      context,
      '删除商品种类',
      '删除“${c['name']}”后，关联商品名称变为未分类；子分类保留并移到顶层。',
    )) {
      return;
    }
    await widget.store.deleteCategory(c['category_id']);
  }

  List<Widget> pendingFirst(
    List<Map<String, dynamic>> rows,
    bool Function(Map<String, dynamic>) isPending,
    Widget Function(Map<String, dynamic>) buildRow,
  ) {
    final pending = rows.where(isPending).toList();
    final completed = rows.where((row) => !isPending(row)).toList();
    return [
      ...pending.map(buildRow),
      if (pending.isNotEmpty && completed.isNotEmpty)
        const Divider(
          key: ValueKey('catalog-completion-divider'),
          thickness: 0.5,
          height: 24,
        ),
      ...completed.map(buildRow),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: TextButton(onPressed: load, child: const Text('加载失败，点击重试')),
      );
    }
    if (loading) return const Center(child: CircularProgressIndicator());
    final uncategorizedId = categories
        .where((c) => c['system_key'] == 'uncategorized')
        .firstOrNull?['category_id'];
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 110),
        children: [
          PageHeading(
            title: '商品管理',
            subtitle: '将票面写法归为你熟悉的商品与种类',
            trailing: TextButton.icon(
              icon: const Icon(Icons.storefront_outlined),
              label: const Text('商店名称'),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LogoAliasesPage(
                      store: widget.store,
                      receiptId: null,
                      suggestedName: '',
                    ),
                  ),
                );
                await load();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (index, label) in [
                  '票据名称',
                  '商品名称',
                  '商品分类',
                  '商品种类',
                ].indexed)
                  ChoiceChip(
                    label: Text(label),
                    avatar: Icon(
                      [
                        Icons.receipt_long_outlined,
                        Icons.sell_outlined,
                        Icons.account_tree_outlined,
                        Icons.category_outlined,
                      ][index],
                      size: 17,
                    ),
                    selected: tab == index,
                    onSelected: (_) => setState(() => tab = index),
                  ),
              ],
            ),
          ),
          if (saving) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (tab == 0) ...[
                  const _Headings('票面名称', '商品名称'),
                  if (printedNames.isEmpty) const Text('识别或录入收据后，可在这里设置商品名称。'),
                  ...pendingFirst(
                    printedNames,
                    (p) =>
                        (p['product_name'] as String?)?.trim().isEmpty ?? true,
                    (p) => _ChoiceRow(
                      key: ValueKey('printed-${p['printed_name_id']}'),
                      label: p['raw_name'],
                      value: p['product_name'] ?? '',
                      fieldLabel: '商品名称',
                      enabled: !saving,
                      options: {
                        for (final n in productNames)
                          n['name'] as String: n['name'] as String,
                      },
                      save: (value, existing) => action(
                        () => widget.store.saveProductName(
                          p['printed_name_id'],
                          value,
                        ),
                      ),
                    ),
                  ),
                ],
                if (tab == 1) ...[
                  if (productNames.isEmpty) const Text('还没有商品名称，请先在票据名称中设置。'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final n in productNames)
                        InputChip(
                          label: Text(n['name']),
                          onPressed: saving
                              ? null
                              : () async {
                                  await Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ProductReceiptsPage(
                                        store: widget.store,
                                        productNameId: n['product_name_id'],
                                        name: n['name'],
                                        zone: widget.zone,
                                        onReceipt: widget.onReceipt,
                                      ),
                                    ),
                                  );
                                  if (mounted) await load();
                                },
                          deleteIcon: const Icon(Icons.close, size: 18),
                          deleteButtonTooltipMessage: '删除商品名称',
                          onDeleted: saving
                              ? null
                              : () => action(() => removeName(n)),
                        ),
                    ],
                  ),
                ],
                if (tab == 3) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in categories)
                        InputChip(
                          label: Text(c['path']),
                          onPressed: saving
                              ? null
                              : () => action(() => editCategory(c)),
                          deleteIcon: const Icon(Icons.close, size: 18),
                          deleteButtonTooltipMessage: '删除商品种类',
                          onDeleted: saving || c['system_key'] != null
                              ? null
                              : () => action(() => removeCategory(c)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('添加种类'),
                        onPressed: saving
                            ? null
                            : () => action(() => editCategory(null)),
                      ),
                    ],
                  ),
                ],
                if (tab == 2) ...[
                  const _Headings('商品名称', '商品种类'),
                  ...pendingFirst(
                    productNames,
                    (n) =>
                        n['category_id'] == null ||
                        n['category_id'] == uncategorizedId,
                    (n) => _ChoiceRow(
                      key: ValueKey('category-${n['product_name_id']}'),
                      label: n['name'],
                      value:
                          categories
                              .where(
                                (c) => c['category_id'] == n['category_id'],
                              )
                              .firstOrNull?['path'] ??
                          '未分类',
                      fieldLabel: '商品种类',
                      enabled: !saving,
                      options: {
                        for (final c in categories)
                          c['category_id'] as String: c['path'] as String,
                      },
                      save: (value, existing) => action(
                        () => widget.store.classifyProductName(
                          n['product_name_id'],
                          value,
                          existing: existing,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Headings extends StatelessWidget {
  final String left, right;
  const _Headings(this.left, this.right);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(left, style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: Text(right, style: Theme.of(context).textTheme.titleSmall),
        ),
      ],
    ),
  );
}

class _ChoiceRow extends StatefulWidget {
  final String label, value, fieldLabel;
  final Map<String, String> options;
  final bool enabled;
  final Future<void> Function(String, bool) save;
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.fieldLabel,
    required this.options,
    required this.enabled,
    required this.save,
  });
  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  late final TextEditingController controller;
  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _ChoiceRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) controller.text = widget.value;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> submit(String value) async {
    final matches = widget.options.entries
        .where((e) => e.value == value.trim())
        .toList();
    await widget.save(
      matches.length == 1 ? matches.single.key : value,
      matches.length == 1,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 500;
      final label = Text(
        widget.label,
        maxLines: compact ? 2 : 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
      final field = TextField(
        controller: controller,
        enabled: widget.enabled,
        onSubmitted: submit,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          isDense: true,
          hintText: '输入或选择',
          labelText: widget.fieldLabel,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<String>(
                tooltip: '选择${widget.fieldLabel}',
                enabled: widget.enabled && widget.options.isNotEmpty,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.arrow_drop_down),
                onSelected: (value) {
                  controller.text = widget.options[value]!;
                  widget.save(value, true);
                },
                itemBuilder: (_) => [
                  for (final e in widget.options.entries)
                    PopupMenuItem(value: e.key, child: Text(e.value)),
                ],
              ),
              IconButton(
                tooltip: '保存${widget.fieldLabel}',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.check, size: 18),
                onPressed: widget.enabled
                    ? () => submit(controller.text)
                    : null,
              ),
            ],
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [label, const SizedBox(height: 7), field],
              )
            : Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: label,
                    ),
                  ),
                  Expanded(child: field),
                ],
              ),
      );
    },
  );
}
