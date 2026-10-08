import '../l10n/strings.dart';

import 'package:flutter/material.dart';

import '../data/store.dart';
import 'common.dart';
import 'catalog_search.dart';
import 'category_editor.dart';
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
  final visitedTabs = <int>{0};
  final scrollControllers = List.generate(4, (_) => ScrollController());
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final controller in scrollControllers) {
      controller.dispose();
    }
    super.dispose();
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
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => CategoryEditorDialog(
        store: widget.store,
        category: category,
        categories: categories,
      ),
    );
    if (saved == true) await load();
  }

  Future<void> removeName(Map<String, dynamic> n) async {
    if (!await confirm(
      context,
      context.tr("删除商品名称"),
      context.tr("删除“{0}”及其名称关联；保留所有收据和照片，相关商品恢复显示票面名称。", [n['name']]),
    )) {
      return;
    }
    await widget.store.deleteProductName(n['product_name_id']);
  }

  Future<void> removeCategory(Map<String, dynamic> c) async {
    if (!await confirm(
      context,
      context.tr("删除商品种类"),
      context.tr("删除“{0}”后，关联商品名称变为未分类；子分类保留并移到顶层。", [c['name']]),
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
  Widget build(BuildContext context) => IndexedStack(
    index: tab,
    children: [
      for (var index = 0; index < 4; index++)
        visitedTabs.contains(index)
            ? KeyedSubtree(
                key: ValueKey('tab-$index'),
                child: PrimaryScrollController(
                  controller: scrollControllers[index],
                  child: buildTab(context, index),
                ),
              )
            : const SizedBox.shrink(),
    ],
  );

  Widget buildTab(BuildContext context, int tab) {
    if (error != null) {
      return Center(
        child: TextButton(
          onPressed: load,
          child: Text(context.tr("加载失败，点击重试")),
        ),
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
            title: context.tr("商品"),
            subtitle: context.tr("将票面写法归为你熟悉的商品与种类"),
            trailing: TextButton.icon(
              icon: const Icon(Icons.storefront_outlined),
              label: Text(context.tr("店铺")),
              onPressed: () async {
                await openPageOverlay<void>(
                  context,
                  LogoAliasesPage(
                    embedded: false,
                    store: widget.store,
                    receiptId: null,
                    suggestedName: '',
                  ),
                );
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
                  context.tr("票据名称"),
                  context.tr("商品名称"),
                  context.tr("商品分类"),
                  context.tr("商品种类"),
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
                    onSelected: (_) => setState(() {
                      visitedTabs.add(index);
                      this.tab = index;
                    }),
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
                  _Headings(context.tr("票面名称"), context.tr("商品名称")),
                  if (printedNames.isEmpty)
                    Text(context.tr("识别或录入收据后，可在这里设置商品名称。")),
                  ...pendingFirst(
                    printedNames,
                    (p) =>
                        (p['product_name'] as String?)?.trim().isEmpty ?? true,
                    (p) => _ChoiceRow(
                      key: ValueKey('printed-${p['printed_name_id']}'),
                      label: p['raw_name'],
                      value: p['product_name'] ?? '',
                      fieldLabel: context.tr("商品名称"),
                      store: widget.store,
                      component: 'product_names',
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
                  if (productNames.isEmpty)
                    Text(context.tr("还没有商品名称，请先在票据名称中设置。")),
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
                                  await openPageOverlay<void>(
                                    context,
                                    ProductReceiptsPage(
                                      store: widget.store,
                                      productNameId: n['product_name_id'],
                                      name: n['name'],
                                      zone: widget.zone,
                                      onReceipt: widget.onReceipt,
                                    ),
                                  );
                                },
                          deleteIcon: const Icon(Icons.close, size: 18),
                          deleteButtonTooltipMessage: context.tr("删除商品名称"),
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
                          onPressed: saving ? null : () => editCategory(c),
                          deleteIcon: const Icon(Icons.close, size: 18),
                          deleteButtonTooltipMessage: context.tr("删除商品种类"),
                          onDeleted: saving || c['system_key'] != null
                              ? null
                              : () => action(() => removeCategory(c)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(context.tr("添加种类")),
                        onPressed: saving ? null : () => editCategory(null),
                      ),
                    ],
                  ),
                ],
                if (tab == 2) ...[
                  _Headings(context.tr("商品名称"), context.tr("商品种类")),
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
                          context.tr("未分类"),
                      fieldLabel: context.tr("商品种类"),
                      store: widget.store,
                      component: 'categories',
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
  final AppStore store;
  final String component;
  final bool enabled;
  final Future<void> Function(String, bool) save;
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.fieldLabel,
    required this.options,
    required this.store,
    required this.component,
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
      final field = CatalogSearchField(
        store: widget.store,
        component: widget.component,
        label: widget.fieldLabel,
        labelField: widget.component == 'categories' ? 'path' : 'name',
        onSelected: (row) => widget.save(
          row[widget.component == 'categories' ? 'category_id' : 'name'],
          true,
        ),
        controller: controller,
        enabled: widget.enabled,
        onSubmitted: submit,
        suffix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<String>(
              tooltip: context.tr("选择{0}", [widget.fieldLabel]),
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
              tooltip: context.tr("保存{0}", [widget.fieldLabel]),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.check, size: 18),
              onPressed: widget.enabled ? () => submit(controller.text) : null,
            ),
          ],
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
