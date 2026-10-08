import '../l10n/strings.dart';

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

class _ReportsPageState extends State<ReportsPage> with WidgetsBindingObserver {
  String period = 'month', currency = 'USD', group = 'category';
  String? category, receiptType;
  int window = 0, request = 0;
  int? selectedOffset;
  final Set<String> visibleSeries = {};
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic>? report, previous, bounds, trend;
  String? error;
  bool choosingLines = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load(keepCurrent: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load(keepCurrent: true);
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
          'receipt_type': receiptType,
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
        receiptType: receiptType,
      );
      final prior = await widget.store.report(
        r['previous_start'],
        r['start'],
        cat,
        widget.zone,
        receiptType: receiptType,
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
    setState(() {
      selectedOffset = points[index]['offset'] as int;
    });
    await load(keepCurrent: true);
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
    if (choosingLines) return;
    setState(() => choosingLines = true);
    final token = request + 1;
    await load(keepCurrent: true);
    if (!mounted) return;
    setState(() => choosingLines = false);
    if (request != token || error != null) return;
    final rows = (trend?['series'] as List? ?? [])
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final expanded = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) {
          Widget option(Map<String, dynamic> row, {required bool product}) {
            final disabled =
                !(row['has_activity'] as bool? ??
                    (row['values'] as List).any((value) => value != 0));
            return CheckboxListTile(
              title: Text(row['label']),
              enabled: !disabled,
              subtitle: Text(
                disabled
                    ? context.tr("当前范围无消费")
                    : product
                    ? context.tr("商品")
                    : ((row['depth'] as int? ?? 0) > 0
                          ? context.tr("{0} · 分类合计", [row['path']])
                          : row['group'] == 'receipt_type'
                          ? context.tr("店铺类别合计")
                          : context.tr("分类合计")),
              ),
              value: !disabled && visibleSeries.contains(row['key']),
              onChanged: disabled
                  ? null
                  : (selected) {
                      setState(() {
                        if (selected == true) {
                          visibleSeries.add(row['key']);
                        } else {
                          visibleSeries.remove(row['key']);
                        }
                      });
                      updateSheet(() {});
                    },
            );
          }

          Widget categoryOption(Map<String, dynamic> category) {
            final products = rows
                .where(
                  (row) =>
                      row['group'] == 'product' &&
                      (row['category_keys'] as List).contains(category['key']),
                )
                .toList();
            final open = expanded.contains(category['key']);
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(child: option(category, product: false)),
                    if (products.isNotEmpty)
                      Tooltip(
                        message: context.tr("{0}{1}商品", [
                          open ? context.tr("收起") : context.tr("展开"),
                          category['label'],
                        ]),
                        child: TextButton.icon(
                          onPressed: () => updateSheet(() {
                            if (open) {
                              expanded.remove(category['key']);
                            } else {
                              expanded.add(category['key']);
                            }
                          }),
                          icon: Icon(
                            open ? Icons.expand_less : Icons.expand_more,
                          ),
                          label: Text(context.tr("{0} 商品", [products.length])),
                        ),
                      ),
                  ],
                ),
                if (open)
                  for (final product in products)
                    Padding(
                      padding: const EdgeInsets.only(left: 20),
                      child: option(product, product: true),
                    ),
                const Divider(height: 1),
              ],
            );
          }

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .68,
              child: ListView(
                children: [
                  ListTile(
                    title: Text(context.tr("趋势曲线")),
                    subtitle: Text(
                      context.tr("分类默认折叠，点击箭头展开商品；分类与商品可独立勾选。无消费选项灰显，总金额始终显示。"),
                    ),
                  ),
                  if (rows.isEmpty)
                    ListTile(title: Text(context.tr("还没有可选曲线"))),
                  for (final t in rows.where(
                    (r) => r['group'] == 'receipt_type',
                  ))
                    option(t, product: false),
                  for (final category in rows.where(
                    (row) => row['group'] == 'category',
                  ))
                    categoryOption(category),
                ],
              ),
            ),
          );
        },
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
                  itemDisplayName(
                    context,
                    l['product_name'],
                    l['raw_name'],
                    l['kind'],
                  ),
                ),
                subtitle: Text(
                  '${l['raw_store']} · ${dateText(l['occurred_at_utc_ms'], widget.zone)}',
                ),
                trailing: Text(money(l['amount_minor'], currency)),
                onTap: () async {
                  await widget.onReceipt(l['receipt_id']);
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
    final selectedSeriesCount = trendSeries
        .where(
          (row) =>
              visibleSeries.contains(row['key']) &&
              (row['has_activity'] as bool? ??
                  (row['values'] as List).any((value) => value != 0)),
        )
        .length;
    final selectedIndex = trendPoints.indexWhere(
      (p) => p['offset'] == selectedOffset,
    );
    return RefreshIndicator(
      onRefresh: () => load(keepCurrent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 116),
        children: [
          Text(
            context.tr("报表"),
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 4),
          Text(
            context.tr("按交易日期汇总所有已确认收据"),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            key: ValueKey('report-receipt-type-$receiptType'),
            initialValue:
                trendSeries.any((t) => t['key'] == 'receipt_type:$receiptType')
                ? receiptType
                : '',
            decoration: InputDecoration(labelText: context.tr("店铺类别统计范围")),
            items: [
              DropdownMenuItem(value: '', child: Text(context.tr("全部店铺类别"))),
              for (final t in trendSeries.where(
                (r) => r['group'] == 'receipt_type',
              ))
                DropdownMenuItem(
                  value: (t['key'] as String).substring(13),
                  child: Text(t['label']),
                ),
            ],
            onChanged: (value) {
              setState(() {
                receiptType = value == '' ? null : value;
              });
              load(keepCurrent: false);
            },
          ),
          const SizedBox(height: 16),
          if (trendPoints.isNotEmpty) ...[
            Text(
              context.tr("消费趋势"),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              context.tr("纵轴 {0} · 横轴 时间 · 点击数据点查看明细", [currency]),
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
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in {
                'day': context.tr("日"),
                'week': context.tr("周"),
                'month': context.tr("月"),
                'quarter': context.tr("季"),
                'year': context.tr("年"),
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
              if (trendPoints.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: choosingLines ? null : chooseLines,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    context.tr("曲线{0}", [
                      selectedSeriesCount == 0 ? '' : ' $selectedSeriesCount',
                    ]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            key: ValueKey('report-receipt-type-$receiptType'),
            initialValue:
                trendSeries.any((t) => t['key'] == 'receipt_type:$receiptType')
                ? receiptType
                : '',
            decoration: InputDecoration(labelText: context.tr("店铺类别统计范围")),
            items: [
              DropdownMenuItem(value: '', child: Text(context.tr("全部店铺类别"))),
              for (final t in trendSeries.where(
                (r) => r['group'] == 'receipt_type',
              ))
                DropdownMenuItem(
                  value: (t['key'] as String).substring(13),
                  child: Text(t['label']),
                ),
            ],
            onChanged: (value) {
              setState(() {
                receiptType = value == '' ? null : value;
              });
              load(keepCurrent: false);
            },
          ),
          const SizedBox(height: 16),
          if (trendPoints.isNotEmpty) ...[
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => changeWindow(-1),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(context.tr("更早趋势")),
                ),
                const Spacer(),
                if (window < 0)
                  TextButton.icon(
                    onPressed: () => changeWindow(1),
                    icon: const Icon(Icons.chevron_right),
                    label: Text(context.tr("更新趋势")),
                  ),
              ],
            ),
            Text(
              context.tr("已选 {0}{1}", [
                bounds?['label'] ?? '',
                bounds?['unfinished'] == true ? context.tr(" · 当前周期未结束") : '',
              ]),
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
                    context.tr("统一显示 {0} · 交易日汇率由后端获取", [currency]),
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
            title: Text(context.tr("统计范围")),
            subtitle: Text(
              category == null
                  ? context.tr("全部分类")
                  : categories
                            .where((c) => c['category_id'] == category)
                            .firstOrNull?['path'] ??
                        context.tr("分类"),
            ),
            trailing: const Icon(Icons.filter_list),
            onTap: () async {
              final id = await chooseCategory(context, [
                {'category_id': 'all', 'path': context.tr("全部分类")},
                ...categories,
              ], category ?? 'all');
              if (id != null) {
                category = id == 'all' ? null : id;
                load(keepCurrent: false);
              }
            },
          ),
          if (error != null) ...[
            Notice(
              context.tr("报表更新失败：{0}\n当前显示的可能是上次结果。", [
                context.translatedMessage(error!),
              ]),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => load(keepCurrent: true),
                icon: const Icon(Icons.refresh),
                label: Text(context.tr("重试统计")),
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
                    context.tr("本期净支出"),
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
                    context.tr("上期 {0}", [money(previous!['net'], currency)]),
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
                Text(context.tr("支出 {0}", [money(spend, currency)])),
                Text(context.tr("优惠 {0}", [money(discounts, currency)])),
                Text(context.tr("商品退款 {0}", [money(refunds, currency)])),
              ],
            ),
            if (report!['difference'] != null && report!['difference'] != 0)
              Notice(
                context.tr("票据待核对差额 {0}", [
                  money(report!['difference'], currency),
                ]),
              ),
            if (report!['rounding_adjustment'] != null &&
                report!['rounding_adjustment'] != 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.tr("逐项换算舍入差额 {0}", [
                    money(report!['rounding_adjustment'], currency),
                  ]),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.muted(context),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Text(
              context.tr("支出去向"),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'receipt_type',
                  label: Text(context.tr("店铺类别")),
                ),
                ButtonSegment(
                  value: 'category',
                  label: Text(context.tr("商品分类")),
                ),
                ButtonSegment(value: 'product', label: Text(context.tr("商品"))),
              ],
              selected: {group},
              onSelectionChanged: (g) => setState(() => group = g.first),
            ),
            const SizedBox(height: 12),
            if (ordered.isEmpty)
              Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  context.tr("这个周期还没有可统计的明细。"),
                  textAlign: TextAlign.center,
                ),
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
                onTap: () {
                  if (group == 'receipt_type') {
                    setState(() {
                      receiptType = (entry['key'] as String).substring(13);
                      category = null;
                      group = 'category';
                    });
                    load(keepCurrent: false);
                    return;
                  }
                  drill(
                    entry['label'],
                    entries
                        .where(
                          (l) => (entry['line_ids'] as List).contains(
                            l['line_id'],
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                context.tr("点击汇总查看原始明细。整单优惠、税费和差额不分摊到商品。"),
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
