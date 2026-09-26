import 'package:flutter/material.dart';

import '../data/store.dart';
import 'common.dart';
import 'app_theme.dart';

class LogoAliasesPage extends StatefulWidget {
  final AppStore store;
  final String? receiptId;
  final String suggestedName;
  const LogoAliasesPage({
    super.key,
    required this.store,
    required this.receiptId,
    required this.suggestedName,
  });
  @override
  State<LogoAliasesPage> createState() => _LogoAliasesPageState();
}

class _LogoAliasesPageState extends State<LogoAliasesPage> {
  List<dynamic>? logos;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
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
          title: const Text('确认 Logo 与店名'),
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
                decoration: const InputDecoration(labelText: '统一店名'),
              ),
              const Text('确认裁剪图包含这家店的 Logo。以后明确匹配时自动使用此店名。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: name.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('保存别名'),
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
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      flexibleSpace: const FrostedBar(child: SizedBox.expand()),
      title: Text(widget.receiptId == null ? '商店名称' : '收据 Logo'),
    ),
    body: AbsorbPointer(
      absorbing: busy,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          MediaQuery.paddingOf(context).top + 72,
          18,
          32,
        ),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            TextButton(onPressed: load, child: const Text('加载失败，点击重试')),
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
              child: const Text('提取收据顶部 Logo'),
            ),
          if (logos?.isEmpty == true)
            const Text('尚无 Logo 样本。新收据识别完成后会提取顶部候选图；确认店名后加入别名库。'),
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
                    title: Text(logo['name'] ?? '尚未设置店名'),
                    subtitle: Text(
                      logo['detection'] == 'header_candidate'
                          ? '顶部候选区域，请确认是否为 Logo'
                          : '请确认 Logo 和对应店名',
                    ),
                    onTap: () => edit(logo as Map),
                    trailing: logo['name'] == null
                        ? const Icon(Icons.edit)
                        : IconButton(
                            tooltip: '删除商店名称样本',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (!await confirm(
                                context,
                                '删除这个商店名称样本？',
                                '以后识别相似 Logo 时将不再使用这个样本。',
                              )) {
                                return;
                              }
                              await act(() async {
                                await widget.store.request('logos', 'delete', {
                                  'id': logo['logo_id'],
                                  'expected_version':
                                      widget.store.catalogVersion,
                                });
                                await load();
                              });
                            },
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
