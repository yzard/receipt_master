import 'package:flutter/material.dart';

import '../data/store.dart';
import '../domain/models.dart';

import 'common.dart';
import 'app_theme.dart';
import 'report_trend_chart.dart';

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
  int window = 0, request = 0;
  int? selectedOffset;
  final Set<String> visibleSeries = {};
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic>? report, previous, bounds, trend;
  String? error;
  @override
  void initState() {
    super.initState();
    load(keepCurrent: false);
  }

  Future<void> load({required bool keepCurrent}) async {
    final token = ++request;
    final cat = category;
    setState(() {
      if (!keepCurrent) {
        report = null;
        previous = null;
        bounds = null;
        trend = null;
      }
      error = null;
    });
    try {
      final t = Map<String, dynamic>.from(
        await widget.store.request('reports', 'trend', {
          'anchor': DateTime.now().millisecondsSinceEpoch,
          'zone': widget.zone,
          'period': period,
          'window': window,
          'category': cat,
        }),
      );
      final c = await widget.store.categories();
      final points = (t['points'] as List)
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
      final r =
          points.where((p) => p['offset'] == selectedOffset).firstOrNull ??
          points.last;
      final current = await widget.store.report(
        r['start'],
        r['end'],
        cat,
        widget.zone,
      );
      final prior = await widget.store.report(
        r['previous_start'],
        r['start'],
        cat,
        widget.zone,
      );
      if (mounted && token == request) {
        setState(() {
          bounds = r;
          selectedOffset = r['offset'] as int;
          trend = t;
          categories = c;
          report = current;
          previous = prior;
          currency = current['currency'] ?? widget.store.reportCurrency;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && token == request) setState(() => error = e.toString());
    }
  }

  Future<void> selectPoint(int index) async {
    final points = trend?['points'] as List?;
    if (points == null || index < 0 || index >= points.length) return;
    final point = Map<String, dynamic>.from(points[index]);
    final token = ++request;
    setState(() {
      selectedOffset = point['offset'] as int;
      bounds = point;
      report = null;
      previous = null;
      error = null;
    });
    try {
      final current = await widget.store.report(
        point['start'],
        point['end'],
        category,
        widget.zone,
      );
      final prior = await widget.store.report(
        point['previous_start'],
        point['start'],
        category,
        widget.zone,
      );
      if (mounted && token == request) {
        setState(() {
          report = current;
          previous = prior;
          currency = current['currency'] ?? widget.store.reportCurrency;
        });
      }
    } catch (e) {
      if (mounted && token == request) setState(() => error = e.toString());
    }
  }

  void changeWindow(int delta) {
    if (window + delta > 0) return;
    setState(() {
      window += delta;
      selectedOffset = null;
    });
    load(keepCurrent: false);
  }

  Future<void> chooseLines() async {
    final rows = (trend?['series'] as List? ?? [])
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .68,
            child: ListView(
              children: [
                const ListTile(
                  title: Text('趋势曲线'),
                  subtitle: Text('总金额始终显示；选择要对比的商品分类和商品。'),
                ),
                for (final type in ['category', 'product']) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                    child: Text(
                      type == 'category' ? '商品分类' : '商品',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  if (!rows.any((row) => row['group'] == type))
                    const ListTile(title: Text('还没有可选曲线')),
                  for (final row in rows.where((row) => row['group'] == type))
                    CheckboxListTile(
                      title: Text(row['label']?.toString() ?? ''),
                      value: visibleSeries.contains(row['key']),
                      onChanged: (selected) {
                        setState(() {
                          if (selected == true) {
                            visibleSeries.add(row['key'] as String);
                          } else {
                            visibleSeries.remove(row['key']);
                          }
                        });
                        updateSheet(() {});
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
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
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.onReceipt(l['receipt_id']);
                  if (mounted) await load(keepCurrent: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
    final trendPoints = (trend?['points'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p))
        .toList();
    final trendSeries = (trend?['series'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p))
        .toList();
    final selectedIndex = trendPoints.indexWhere(
      (p) => p['offset'] == selectedOffset,
    );
    return RefreshIndicator(
      onRefresh: () => load(keepCurrent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 116),
        children: [
          Text('报表', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 4),
          Text(
            '按交易日期汇总所有已确认收据',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 20),
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
                      window = 0;
                      selectedOffset = null;
                    });
                    load(keepCurrent: false);
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (trendPoints.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '消费趋势',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: chooseLines,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    '曲线${visibleSeries.isEmpty ? '' : ' ${visibleSeries.length}'}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '纵轴 $currency · 横轴 时间 · 点击数据点查看明细',
              style: TextStyle(fontSize: 12, color: AppPalette.muted(context)),
            ),
            const SizedBox(height: 8),
            ReportTrendChart(
              points: trendPoints,
              series: trendSeries,
              visibleSeries: visibleSeries,
              currency: currency,
              selectedIndex: selectedIndex < 0
                  ? trendPoints.length - 1
                  : selectedIndex,
              onSelect: selectPoint,
              onOlder: () => changeWindow(-1),
              onNewer: () => changeWindow(1),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 7,
              children: [
                _TrendLegend('总金额', scheme.primary),
                for (final (index, row) in trendSeries.indexed)
                  if (visibleSeries.contains(row['key']))
                    _TrendLegend(
                      row['label']?.toString() ?? '',
                      ReportTrendChart.seriesColor(
                        index,
                        scheme.tertiary,
                        scheme.secondary,
                      ),
                    ),
              ],
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => changeWindow(-1),
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('更早趋势'),
                ),
                const Spacer(),
                if (window < 0)
                  TextButton.icon(
                    onPressed: () => changeWindow(1),
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('更新趋势'),
                  ),
              ],
            ),
            Text(
              '已选 ${bounds?['label'] ?? ''}${bounds?['unfinished'] == true ? ' · 当前周期未结束' : ''}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.zone,
              style: TextStyle(fontSize: 12, color: AppPalette.muted(context)),
            ),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.currency_exchange, size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '统一显示 $currency · 交易日汇率由后端获取',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppPalette.muted(context),
                    ),
                  ),
                ),
              ],
            ),
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
          if (error != null) ...[
            Notice('报表更新失败：$error\n当前显示的可能是上次结果。'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => load(keepCurrent: true),
                icon: const Icon(Icons.refresh),
                label: const Text('重试统计'),
              ),
            ),
          ],
          if (report == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (report != null) ...[
            Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary,
                    scheme.primary.withValues(alpha: .78),
                  ],
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本期净支出',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary
                          .withValues(alpha: .8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    money(report!['net'], currency),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontSize: 38,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上期 ${money(previous!['net'], currency)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary
                          .withValues(alpha: .8),
                    ),
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
              Notice('票据待核对差额 ${money(report!['difference'], currency)}'),
            if (report!['rounding_adjustment'] != null &&
                report!['rounding_adjustment'] != 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '逐项换算舍入差额 ${money(report!['rounding_adjustment'], currency)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.muted(context),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Text('支出去向', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
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
              _SpendRow(
                label: entry['label'],
                amount: money(entry['amount'], currency),
                proportion: spend > 0
                    ? ((entry['amount'] as int).abs() / spend).clamp(0.0, 1.0)
                    : 0,
                detail: group == 'product'
                    ? (entry['quantity_labels'] as List).join(' / ')
                    : null,
                onTap: () => drill(
                  entry['label'],
                  entries
                      .where(
                        (l) =>
                            (entry['line_ids'] as List).contains(l['line_id']),
                      )
                      .toList(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '点击汇总查看原始明细。整单优惠、税费和差额不分摊到商品。',
                style: TextStyle(
                  fontSize: 12,
                  color: AppPalette.muted(context),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrendLegend extends StatelessWidget {
  const _TrendLegend(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 88,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    ],
  );
}

class _SpendRow extends StatelessWidget {
  const _SpendRow({
    required this.label,
    required this.amount,
    required this.proportion,
    required this.onTap,
    this.detail,
  });
  final String label, amount;
  final String? detail;
  final double proportion;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  amount,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 19),
              ],
            ),
            if (detail?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  detail!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: proportion,
                minHeight: 5,
                backgroundColor: scheme.primary.withValues(alpha: .1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
