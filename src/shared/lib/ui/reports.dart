import 'package:flutter/material.dart';

import '../data/store.dart';
import '../domain/models.dart';

import 'common.dart';

class ReportsPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Future<void> Function(String) onReceipt;
  const ReportsPage({
    super.key,
    required this.store,
    required this.zone,
    required this.onReceipt,
  });
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String period = 'month', currency = 'USD', group = 'category';
  String? category;
  int offset = 0, request = 0;
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic>? report, previous, bounds;
  String? error;
  @override
  void initState() {
    super.initState();
    load(keepCurrent: false);
  }

  Future<void> load({required bool keepCurrent}) async {
    final token = ++request;
    final code = currency, cat = category;
    setState(() {
      if (!keepCurrent) report = null;
      error = null;
    });
    try {
      final r = Map<String, dynamic>.from(
        await widget.store.request('reports', 'range', {
          'anchor': DateTime.now().millisecondsSinceEpoch,
          'zone': widget.zone,
          'period': period,
          'period_offset': offset,
        }),
      );
      final c = await widget.store.categories();
      final current = await widget.store.report(
        r['start'],
        r['end'],
        code,
        cat,
      );
      final prior = await widget.store.report(
        r['previous_start'],
        r['start'],
        code,
        cat,
      );
      if (mounted && token == request) {
        setState(() {
          bounds = r;
          categories = c;
          report = current;
          previous = prior;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && token == request) setState(() => error = e.toString());
    }
  }

  Future<void> drill(String title, List<Map<String, dynamic>> lines) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        builder: (ctx, controller) => ListView(
          controller: controller,
          children: [
            ListTile(
              title: Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final l in lines)
              ListTile(
                title: Text(
                  itemDisplayName(l['product_name'], l['raw_name'], l['kind']),
                ),
                subtitle: Text(
                  '${l['raw_store']} · ${dateText(l['occurred_at_utc_ms'], widget.zone)}',
                ),
                trailing: Text(money(l['amount_minor'], currency)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onReceipt(l['receipt_id']);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = report == null
        ? <Map<String, dynamic>>[]
        : (report!['entries'] as List).cast<Map<String, dynamic>>();
    final ordered = report == null
        ? <Map<String, dynamic>>[]
        : (report!['groups'] as List)
              .map((g) => Map<String, dynamic>.from(g))
              .where((g) => g['group'] == group)
              .toList();
    final spend = report?['spend'] ?? 0,
        discounts = report?['discounts'] ?? 0,
        refunds = report?['refunds'] ?? 0;
    return RefreshIndicator(
      onRefresh: () => load(keepCurrent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in {
                'day': '日',
                'week': '周',
                'month': '月',
                'quarter': '季',
                'year': '年',
              }.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: period == e.key,
                  onSelected: (_) {
                    setState(() {
                      period = e.key;
                      offset = 0;
                    });
                    load(keepCurrent: false);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                tooltip: '上一周期',
                onPressed: () {
                  offset--;
                  load(keepCurrent: false);
                },
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  bounds?['label'] ?? '正在查询周期…',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: '下一周期',
                onPressed: () {
                  offset++;
                  load(keepCurrent: false);
                },
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Text(
            '${widget.zone}${bounds?['unfinished'] == true ? ' · 当前周期未结束' : ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: currency,
            decoration: const InputDecoration(labelText: '币种 · 分别统计'),
            items: currencies.keys
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (c) {
              currency = c!;
              load(keepCurrent: false);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('统计范围'),
            subtitle: Text(
              category == null
                  ? '全部分类'
                  : categories
                            .where((c) => c['category_id'] == category)
                            .firstOrNull?['path'] ??
                        '分类',
            ),
            trailing: const Icon(Icons.filter_list),
            onTap: () async {
              final id = await chooseCategory(context, [
                {'category_id': 'all', 'path': '全部分类'},
                ...categories,
              ], category ?? 'all');
              if (id != null) {
                category = id == 'all' ? null : id;
                load(keepCurrent: false);
              }
            },
          ),
          if (error != null) Notice('报表加载失败：$error'),
          if (report == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (report != null) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: ink,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('净支出', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  Text(
                    money(report!['net'], currency),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上期 ${money(previous!['net'], currency)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Text('支出 ${money(spend, currency)}'),
                Text('优惠 ${money(discounts, currency)}'),
                Text('商品退款 ${money(refunds, currency)}'),
              ],
            ),
            if (report!['difference'] != null && report!['difference'] != 0)
              Notice(
                '待核对差额 ${money(report!['difference'], currency)}\n分类金额加上差额，等于整体净支出。',
              ),
            const SizedBox(height: 20),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'category', label: Text('商品分类')),
                ButtonSegment(value: 'product', label: Text('商品')),
              ],
              selected: {group},
              onSelectionChanged: (g) => setState(() => group = g.first),
            ),
            const SizedBox(height: 12),
            if (ordered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('这个周期还没有可统计的明细。', textAlign: TextAlign.center),
              ),
            for (final entry in ordered)
              Card(
                color: Colors.white,
                elevation: 0,
                child: ListTile(
                  title: Text(entry['label']),
                  subtitle: group == 'product'
                      ? Text((entry['quantity_labels'] as List).join(' / '))
                      : null,
                  trailing: Text(
                    money(entry['amount'], currency),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: () => drill(
                    entry['label'],
                    entries
                        .where(
                          (l) => (entry['line_ids'] as List).contains(
                            l['line_id'],
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '点击汇总查看原始明细。整单优惠、税费和差额不分摊到商品。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
