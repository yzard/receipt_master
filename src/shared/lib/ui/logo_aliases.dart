import '../l10n/strings.dart';

import 'package:flutter/material.dart';

import '../data/store.dart';
import 'common.dart';
import 'app_theme.dart';
import 'receipt_types.dart';

class LogoAliasesPage extends StatefulWidget {
  final AppStore store;
  final String? receiptId;
  final String suggestedName;
  final bool embedded;
  const LogoAliasesPage({
    super.key,
    required this.store,
    required this.receiptId,
    required this.suggestedName,
    required this.embedded,
  });
  @override
  State<LogoAliasesPage> createState() => _LogoAliasesPageState();
}

class _LogoAliasesPageState extends State<LogoAliasesPage> {
  List<dynamic>? logos;
  String? error;
  bool busy = false;
  int tab = 0;
  final visitedTabs = <int>{0};
  final scrollControllers = List.generate(2, (_) => ScrollController());
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
      final result = await widget.store.request('logos', 'list', {
        'receipt_id': widget.receiptId,
      });
      if (mounted) {
        setState(() {
          logos = result as List;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> edit(Map logo) async {
    String name = logo['name'] ?? widget.suggestedName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.tr("确认 Logo 与店名")),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 100,
                child: widget.store.image(
                  Map<String, dynamic>.from(logo),
                  fit: BoxFit.contain,
                ),
              ),
              TextFormField(
                initialValue: name,
                onChanged: (v) => setDialogState(() => name = v),
                decoration: InputDecoration(labelText: context.tr("统一店名")),
              ),
              Text(context.tr("确认裁剪图包含这家店的 Logo。以后明确匹配时自动使用此店名。")),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr("取消")),
            ),
            FilledButton(
              onPressed: name.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(context.tr("保存别名")),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await act(() async {
      await widget.store.request('logos', 'save', {
        'id': logo['logo_id'],
        'name': name.trim(),
        'expected_version': widget.store.catalogVersion,
      });
      if (widget.receiptId != null && mounted) {
        Navigator.pop(context, name.trim());
      } else {
        await load();
      }
    });
  }

  Future<void> act(Future<void> Function() work) async {
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: tab,
    children: [
      for (var index = 0; index < 2; index++)
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
    final body = AbsorbPointer(
      absorbing: busy,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          widget.embedded ? 8 : MediaQuery.paddingOf(context).top + 72,
          18,
          widget.embedded ? 110 : 32,
        ),
        children: [
          if (widget.embedded)
            PageHeading(
              title: context.tr("店铺"),
              subtitle: context.tr("管理店铺名称与店铺类别"),
            ),
          if (widget.receiptId == null) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final (index, label) in [
                  context.tr("店铺名称"),
                  context.tr("店铺类别"),
                ].indexed)
                  ChoiceChip(
                    label: Text(label),
                    selected: tab == index,
                    onSelected: (_) => setState(() {
                      visitedTabs.add(index);
                      this.tab = index;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (widget.receiptId == null && tab == 1)
            ReceiptTypesManager(store: widget.store)
          else ...[
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              TextButton(onPressed: load, child: Text(context.tr("加载失败，点击重试"))),
            if (logos == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (widget.receiptId != null && logos?.isEmpty == true)
              FilledButton(
                onPressed: () => act(() async {
                  await widget.store.request('logos', 'extract', {
                    'receipt_id': widget.receiptId,
                  });
                  await load();
                }),
                child: Text(context.tr("提取收据顶部 Logo")),
              ),
            if (logos?.isEmpty == true)
              Text(context.tr("尚无 Logo 样本。新收据识别完成后会提取顶部候选图；确认店名后加入别名库。")),
            for (final logo in logos ?? [])
              Card(
                child: Column(
                  children: [
                    SizedBox(
                      height: 140,
                      child: widget.store.image(
                        Map<String, dynamic>.from(logo),
                        fit: BoxFit.contain,
                      ),
                    ),
                    ListTile(
                      title: Text(logo['name'] ?? context.tr("尚未设置店名")),
                      subtitle: Text(
                        logo['detection'] == 'header_candidate'
                            ? context.tr("顶部候选区域，请确认是否为 Logo")
                            : context.tr("请确认 Logo 和对应店名"),
                      ),
                      onTap: () => edit(logo as Map),
                      trailing: logo['name'] == null
                          ? const Icon(Icons.edit)
                          : IconButton(
                              tooltip: context.tr("删除店铺名称样本"),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (!await confirm(
                                  context,
                                  context.tr("删除这个店铺名称样本？"),
                                  context.tr("以后识别相似 Logo 时将不再使用这个样本。"),
                                )) {
                                  return;
                                }
                                await act(() async {
                                  await widget.store.request(
                                    'logos',
                                    'delete',
                                    {
                                      'id': logo['logo_id'],
                                      'expected_version':
                                          widget.store.catalogVersion,
                                    },
                                  );
                                  await load();
                                });
                              },
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        flexibleSpace: const FrostedBar(child: SizedBox.expand()),
        title: Text(
          widget.receiptId == null ? context.tr("店铺") : context.tr("收据 Logo"),
        ),
      ),
      body: body,
    );
  }
}
