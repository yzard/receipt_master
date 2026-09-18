import 'logo_aliases.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../domain/models.dart';
import 'common.dart';

class EditorPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final String? receiptId;
  const EditorPage({
    super.key,
    required this.store,
    required this.zone,
    required this.receiptId,
  });
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  ReceiptDraft? draft;
  List<Map<String, dynamic>> categories = [], images = [];
  final fields = <String, TextEditingController>{};
  final selected = <String>{};
  bool busy = false;
  bool dirty = false;
  int currencyPickerVersion = 0;
  String? error;
  Timer? debounce;
  Future<void> pending = Future.value();
  @override
  void initState() {
    super.initState();
    for (final name in ['store', 'branch', 'address', 'country', 'total']) {
      fields[name] = TextEditingController();
    }
    load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      await widget.store.loadPreferences();
      categories = await widget.store.categories();
      final r = widget.receiptId == null
          ? ReceiptDraft.empty(DateTime.now())
          : ReceiptDraft.fromMap(await widget.store.load(widget.receiptId!));
      if (widget.receiptId == null) {
        final map = r.toMap();
        draft = ReceiptDraft.fromMap(
          await widget.store.save(
            map,
            false,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else {
        draft = r;
      }
      populate();
      await refreshImages();
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void populate() {
    final r = draft!;
    fields['store']!.text = r.store;
    fields['branch']!.text = r.branch;
    fields['address']!.text = r.address;
    fields['country']!.text = r.country;
    fields['total']!.text = fixed(r.totalMinor, currencies[r.currency]!);
  }

  Future<void> syncFields() async {
    final r = draft!;
    r.store = fields['store']!.text;
    r.branch = fields['branch']!.text;
    r.address = fields['address']!.text;
    r.country = fields['country']!.text.toUpperCase();
    final result = await widget.store.request('receipts', 'edit', {
      'receipt': r.toMap(),
      'action': 'preview',
      'total_text': fields['total']!.text,
    });
    r.totalMinor = result['totalMinor'];
    r.summary = Map<String, dynamic>.from(result['summary']);
  }

  void changed() {
    dirty = true;
    debounce?.cancel();
    if (draft?.posted == true) {
      debounce = Timer(const Duration(milliseconds: 600), () async {
        try {
          await syncFields();
          if (mounted) setState(() {});
        } catch (e) {
          if (mounted) showError(context, e);
        }
      });
    } else if (draft != null) {
      debounce = Timer(const Duration(milliseconds: 600), () {
        persistDraft().catchError((Object _) {});
      });
    }
  }

  Future<void> persistDraft() {
    final operation = pending.then((_) async {
      if (!mounted || draft == null || draft!.posted) return;
      try {
        await syncFields();
        final map = draft!.toMap();
        final saved = await widget.store.save(
          map,
          false,
          DateTime.now().millisecondsSinceEpoch,
        );
        if (mounted) {
          draft!.revision = saved['revision'];
          draft!.summary = Map<String, dynamic>.from(saved['summary']);
          setState(() => error = null);
        }
      } catch (e) {
        if (mounted) setState(() => error = e.toString());
        rethrow;
      }
    });
    pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> refreshImages() async {
    final id = draft!.id;
    images = await widget.store.images(id);
    draft!.revision = widget.store.versions[id] ?? draft!.revision;
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    debounce?.cancel();
    setState(() => busy = true);
    try {
      await pending;
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> changeTime() async {
    final r = draft!;
    var zone = widget.zone;
    var text = dateText(r.occurredAt, zone);
    bool estimate = r.timeSource.startsWith('estimated');
    final local = TextEditingController(text: text),
        zoneField = TextEditingController(text: zone);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('确认消费时间'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('票面原文：${r.rawTime.isEmpty ? '无' : r.rawTime}'),
                const SizedBox(height: 12),
                TextField(
                  controller: local,
                  decoration: const InputDecoration(
                    labelText: '当地日期时间',
                    helperText: 'YYYY-MM-DD HH:mm',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: zoneField,
                  decoration: const InputDecoration(
                    labelText: '用于解释票面时间的时区',
                    helperText: '例如 America/New_York、Asia/Tokyo',
                  ),
                ),
                CheckboxListTile(
                  value: estimate,
                  onChanged: (v) => set(() => estimate = v!),
                  title: const Text('时间包含估计值'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result != true || !mounted) return;
    try {
      zone = zoneField.text.trim();
      text = local.text;
      final times = await widget.store.request('receipts', 'time_candidates', {
        'text': text,
        'zone': zone,
      }) as List;
      final candidates = times
          .map(
            (t) => DateTime.fromMillisecondsSinceEpoch(t as int, isUtc: true),
          )
          .toList();
      if (!mounted) return;
      if (candidates.isEmpty) throw const InputError('这个当地时间不存在，请检查日期或夏令时');
      DateTime? instant;
      if (candidates.length == 1) {
        instant = candidates.single;
      } else {
        instant = await showDialog<DateTime>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('此时间出现两次，请选择'),
            children: candidates
                .map(
                  (d) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, d),
                    child: Text('UTC ${d.toIso8601String()}'),
                  ),
                )
                .toList(),
          ),
        );
      }
      if (instant == null) return;
      setState(() {
        r.occurredAt = instant!.millisecondsSinceEpoch;
        r.timeSource = estimate ? 'estimated_clock' : 'user_entered';
      });
      changed();
    } catch (e) {
      if (mounted) {
        showError(
          context,
          e is InputError ? e : const InputError('时区名称无效，请使用 IANA 时区名称'),
        );
      }
    }
  }

  Future<void> showEvidence(LineDraft line) async {
    final available = line.evidence
        .where((e) => images.any((p) => p['image_id'] == e['imageId']))
        .toList();
    if (available.isEmpty) {
      showError(context, const InputError('这条明细没有图片位置证据，可从收据顶部查看照片'));
      return;
    }
    final e = available.first,
        photo = images.firstWhere(
          (p) => p['image_id'] == available.first['imageId'],
        );
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(title: const Text('对照票面 · 高亮为识别位置')),
          body: InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: AspectRatio(
                aspectRatio: photo['width_px'] / photo['height_px'],
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.store.image(photo, fit: BoxFit.fill),
                    CustomPaint(painter: EvidencePainter(e)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> editLine(LineDraft? original) async {
    var line = original == null
        ? LineDraft.empty()
        : LineDraft.fromMap(original.toMap());
    final r = draft!;
    try {
      line = LineDraft.fromMap(
        await widget.store.request('receipts', 'display_line', {
          'line': line.toMap(),
          'currency': r.currency,
        }),
      );
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final c = {
      for (final key in [
        'raw',
        'taxCode',
        'sku',
        'productName',
        'weight',
        'quantity',
        'unit',
        'price',
        'amount',
      ])
        key: TextEditingController(),
    };
    c['raw']!.text = line.rawName;
    c['taxCode']!.text = line.taxCode ?? '';
    c['sku']!.text = line.sku ?? '';
    final initialProductName =
        line.productNameEdit ?? line.display['productName'] ?? '';
    c['productName']!.text = initialProductName;
    c['weight']!.text = line.display['weightText'];
    c['quantity']!.text = line.display['quantityText'];
    c['unit']!.text = line.display['quantityUnit'];
    c['price']!.text = line.display['priceText'];
    c['amount']!.text = line.display['amountText'];
    final displayUnit = line.display['weightUnit'];
    bool savingLine = false;
    String? dialogError;
    bool clearWarnings = false;
    final result = await showDialog<LineDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          Widget field(String key, String label) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: c[key],
              decoration: InputDecoration(labelText: label),
              keyboardType:
                  ['weight', 'quantity', 'price', 'amount'].contains(key)
                  ? const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    )
                  : TextInputType.text,
            ),
          );
          return AlertDialog(
            title: Text(original == null ? '添加明细' : '确认明细'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (line.evidence.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => showEvidence(line),
                        icon: const Icon(Icons.image_search),
                        label: const Text('对照原图位置'),
                      ),
                    if (line.warnings.isNotEmpty)
                      Notice(line.warnings.join('\n')),
                    if ((line.display['pricingNote'] ?? '').isNotEmpty)
                      Notice(line.display['pricingNote']!),
                    DropdownButtonFormField<String>(
                      initialValue: line.kind,
                      decoration: const InputDecoration(labelText: '明细类型'),
                      items: kindLabels.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => set(() {
                        line.kind = value!;
                        line.categoryId =
                            systemCategories[value] ?? line.categoryId;
                      }),
                    ),
                    const SizedBox(height: 12),
                    field('raw', '票面名称'),
                    if (line.kind == 'product') ...[
                      field('productName', '商品名称'),
                      field('taxCode', '税码（一个字符，可留空）'),
                      field('sku', '商店 SKU（可留空）'),
                      field('weight', '重量 $displayUnit（可留空）'),
                      TextButton.icon(
                        onPressed: () async {
                          final matches = await widget.store.suggest(
                            c['raw']!.text,
                          );
                          if (!ctx.mounted) return;
                          if (matches.isEmpty) {
                            showError(
                              ctx,
                              const InputError('没有此商品的历史规格，请手工填写'),
                            );
                            return;
                          }
                          final chosen = await showDialog<Map<String, dynamic>>(
                            context: ctx,
                            builder: (pick) => SimpleDialog(
                              title: const Text('选择历史规格'),
                              children: matches
                                  .map(
                                    (m) => SimpleDialogOption(
                                      onPressed: () => Navigator.pop(pick, m),
                                      child: Text(
                                        '${m['raw_name']} · ${m['weight_label']}',
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          );
                          if (chosen != null) {
                            set(() {
                              c['weight']!.text = chosen['weight_text'];
                              line.weightMg = chosen['weight_mg'];
                              line.categoryId = chosen['category_id'];
                            });
                          }
                        },
                        icon: const Icon(Icons.history),
                        label: const Text('选择以前买过的规格'),
                      ),
                      field('quantity', '购买数量（可留空）'),
                      field('unit', '数量单位，例如 ea、g、lb'),
                    ],
                    field('price', '单价（优惠为负数，可留空）'),
                    field('amount', '这一行的实际金额'),
                    if (line.kind == 'item_discount')
                      DropdownButtonFormField<String>(
                        initialValue:
                            r.lines.any(
                              (l) =>
                                  l.id == line.discountTarget &&
                                  l.kind == 'product',
                            )
                            ? line.discountTarget
                            : null,
                        decoration: const InputDecoration(labelText: '优惠对应的商品'),
                        items: r.lines
                            .where(
                              (l) => l.kind == 'product' && l.id != line.id,
                            )
                            .map(
                              (l) => DropdownMenuItem(
                                value: l.id,
                                child: Text(
                                  l.rawName.isEmpty ? '未命名商品' : l.rawName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            set(() => line.discountTarget = value),
                      ),
                    if (line.kind != 'item_discount')
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('统计分类'),
                        subtitle: Text(
                          categories.firstWhere(
                            (p) => p['category_id'] == line.categoryId,
                          )['path'],
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final chosen = await chooseCategory(
                            ctx,
                            categories,
                            line.categoryId,
                          );
                          if (chosen != null) {
                            set(() => line.categoryId = chosen);
                          }
                        },
                      ),
                    if (line.warnings.isNotEmpty)
                      CheckboxListTile(
                        value: clearWarnings,
                        onChanged: (v) => set(() => clearWarnings = v!),
                        title: const Text('已检查并接受以上提示'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    if (dialogError != null) Notice(dialogError!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: savingLine
                    ? null
                    : () async {
                        set(() => savingLine = true);
                        try {
                          line.rawName = c['raw']!.text;
                          line.taxCode = c['taxCode']!.text;
                          line.sku = c['sku']!.text;
                          if (c['productName']!.text != initialProductName) {
                            line.productNameEdit = c['productName']!.text;
                          }
                          line = LineDraft.fromMap(
                            await widget.store.request(
                              'receipts',
                              'prepare_line',
                              {
                                'currency': r.currency,
                                'line': line.toMap(),
                                'fields': {
                                  'weightText': c['weight']!.text,
                                  'weightUnit': displayUnit,
                                  'quantityText': c['quantity']!.text,
                                  'quantityUnit': c['unit']!.text,
                                  'priceText': c['price']!.text,
                                  'amountText': c['amount']!.text,
                                },
                              },
                            ),
                          );
                          if (!ctx.mounted) return;
                          if (clearWarnings) line.warnings.clear();
                          final trial = ReceiptDraft.fromMap(r.toMap());
                          final index = trial.lines.indexWhere(
                            (l) => l.id == line.id,
                          );
                          if (index < 0) {
                            trial.lines.add(line);
                          } else {
                            trial.lines[index] = line;
                          }
                          trial.validate(false);
                          Navigator.pop(ctx, line);
                        } catch (e) {
                          if (ctx.mounted) {
                            set(() => dialogError = e.toString());
                          }
                        } finally {
                          if (ctx.mounted) set(() => savingLine = false);
                        }
                      },
                child: const Text('应用修改'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null && mounted) {
      setState(() {
        final index = r.lines.indexWhere((l) => l.id == result.id);
        if (index < 0) {
          r.lines.add(result);
        } else {
          r.lines[index] = result;
        }
      });
      changed();
    }
  }

  Future<void> removeLine(LineDraft line) async {
    if (draft!.lines.any((l) => l.discountTarget == line.id)) {
      showError(context, const InputError('请先删除或重新关联这个商品的优惠'));
      return;
    }
    setState(() => draft!.lines.remove(line));
    changed();
  }

  Future<ReceiptDraft> editReceipt(
    String action,
    Map<String, dynamic> input,
  ) async {
    await syncFields();
    return ReceiptDraft.fromMap(
      await widget.store.request('receipts', 'edit', {
        'receipt': draft!.toMap(),
        'action': action,
        ...input,
      }),
    );
  }

  Future<void> split() async {
    if (selected.length != 1) return;
    final amount = await askText(
      context,
      '拆分：第一行金额',
      '',
      '两行金额之和将保持不变；数量需要重新确认',
    );
    if (amount == null) return;
    final result = await editReceipt('split', {
      'selected': selected.toList(),
      'amount_text': amount,
    });
    if (!mounted) return;
    setState(() {
      draft = result;
      selected.clear();
      populate();
    });
    changed();
  }

  Future<void> merge() async {
    final result = await editReceipt('merge', {'selected': selected.toList()});
    if (!mounted) return;
    setState(() {
      draft = result;
      selected.clear();
      populate();
    });
    changed();
  }

  Future<void> save() async {
    await act(() async {
      await syncFields();
      draft!.validate(true);
      final map = draft!.toMap();
      final dup = await widget.store.duplicates(map);
      if (dup.isNotEmpty &&
          mounted &&
          !await confirm(
            context,
            '疑似重复收据',
            '${dup.map((r) => '${r['raw_store']} · ${money(r['total_minor'], draft!.currency)} · ${dateText(r['occurred_at_utc_ms'], widget.zone)}').join('\n')}\n仍然保存这张收据？',
          )) {
        return;
      }
      if (!mounted) return;
      final hasWarnings =
          draft!.difference != 0 ||
          draft!.lines.any((l) => l.warnings.isNotEmpty) ||
          draft!.timeSource.startsWith('estimated');
      if (hasWarnings &&
          !await confirm(
            context,
            '确认保存',
            '这张收据含黄色提示或估计时间。差额 ${money(draft!.difference, draft!.currency)} 会单独显示，是否保存？',
          )) {
        return;
      }
      await widget.store.save(map, true, DateTime.now().millisecondsSinceEpoch);
      if (mounted) Navigator.pop(context);
    });
  }

  Widget photoStrip(ReceiptDraft r) => SizedBox(
    height: 170,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: images.length,
      itemBuilder: (ctx, i) {
        final photo = images[i];
        return SizedBox(
          width: 152,
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => Dialog.fullscreen(
                      child: Scaffold(
                        appBar: AppBar(title: Text('第 ${i + 1} 段')),
                        body: InteractiveViewer(
                          maxScale: 8,
                          child: Center(child: widget.store.image(photo)),
                        ),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: widget.store.image(
                      photo,
                      fit: BoxFit.cover,
                      width: 110,
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '向前移动',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: i == 0
                        ? null
                        : () => act(() async {
                            final ids = images
                                .map((p) => p['image_id'] as String)
                                .toList();
                            final old = ids.removeAt(i);
                            ids.insert(i - 1, old);
                            final id = r.id;
                            await widget.store.reorderImages(id, ids);
                            await refreshImages();
                          }),
                  ),
                  IconButton(
                    tooltip: '旋转 90°',
                    icon: const Icon(Icons.rotate_right),
                    onPressed: () => act(() async {
                      final image = photo['image_id'] as String;
                      await widget.store.rotateImage(r.id, image);
                      for (final l in r.lines) {
                        for (final e in l.evidence.where(
                          (e) => e['imageId'] == image,
                        )) {
                          final x0 = e['x0'],
                              y0 = e['y0'],
                              x1 = e['x1'],
                              y1 = e['y1'];
                          e['x0'] = 1 - y1;
                          e['y0'] = x0;
                          e['x1'] = 1 - y0;
                          e['y1'] = x1;
                        }
                      }
                      await refreshImages();
                    }),
                  ),
                  IconButton(
                    tooltip: '删除此段',
                    icon: const Icon(Icons.close),
                    onPressed: () => act(() async {
                      final id = r.id, image = photo['image_id'] as String;
                      await widget.store.removeImage(id, image);
                      for (final l in r.lines) {
                        l.evidence.removeWhere((e) => e['imageId'] == image);
                      }
                      await refreshImages();
                    }),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
  Future<void> leave() async {
    await act(() async {
      if (draft!.posted) {
        if (dirty && !await confirm(context, '放弃未保存修改？', '正式记录仍保留上次确认的数据。')) {
          return;
        }
      } else {
        try {
          await persistDraft();
        } catch (_) {
          if (!mounted ||
              !await confirm(
                context,
                '草稿保存失败，放弃未保存修改并退出？',
                '服务器已保存的收据和照片会保留，本次未保存的修改将丢弃。',
              )) {
            return;
          }
        }
      }
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> retryRecognition() async {
    await act(() async {
      final r = draft!;
      if (images.isEmpty) return;
      if (r.posted &&
          dirty &&
          !await confirm(context, '放弃未保存修改并重新识别？', '收据将转回草稿，重新识别照片。')) {
        return;
      }
      final jobs = await widget.store.request('recognition', 'list', {
        'receipt_id': r.id,
      });
      final active = (jobs as List).any(
        (job) => ['queued', 'running'].contains(job['status']),
      );
      if (active) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('正在后台识别，请稍候')));
        }
        return;
      }
      await persistDraft();
      await widget.store.startRecognition(
        r.id,
        r.revision,
        widget.zone,
        requestKey: null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已提交重新识别，可继续处理其他收据')));
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = draft;
    if (r == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('录入收据')),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Text(error!),
        ),
      );
    }
    Widget text(String key, String label) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: fields[key],
        enabled: !busy,
        onChanged: (_) => changed(),
        decoration: InputDecoration(labelText: label),
        keyboardType: key == 'total'
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !busy) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(r.posted ? '编辑收据' : '收据草稿'),
          actions: [
            IconButton(
              tooltip: images.isEmpty ? '没有照片可供识别' : '重新识别',
              icon: const Icon(Icons.refresh),
              onPressed: busy || images.isEmpty ? null : retryRecognition,
            ),
            IconButton(
              tooltip: '永久删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy
                  ? null
                  : () async {
                      if (await confirm(
                        context,
                        '永久删除收据？',
                        '收据、照片和识别记录将从服务器删除，无法恢复。',
                      )) {
                        await act(() async {
                          await widget.store.purge(r.id);
                          if (context.mounted) Navigator.pop(context);
                        });
                      }
                    },
            ),
          ],
        ),
        body: AbsorbPointer(
          absorbing: busy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (error != null) Notice('草稿尚未保存：$error'),
              if (images.isNotEmpty) photoStrip(r),
              for (final photo in images.where(
                (p) => p['quality_warning'] != null,
              ))
                Notice(photo['quality_warning']),
              const SizedBox(height: 16),
              if (images.isNotEmpty && fields['store']!.text.isEmpty)
                const Notice('尚未匹配店名，请确认 Logo 并设置商店名称。'),
              text('store', '店名 / 连锁店'),
              if (images.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.image_search),
                  label: const Text('商店名称'),
                  onPressed: () => act(() async {
                    final name = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LogoAliasesPage(
                          store: widget.store,
                          receiptId: r.id,
                          suggestedName: fields['store']!.text,
                        ),
                      ),
                    );
                    if (name != null && mounted) {
                      fields['store']!.text = name;
                      changed();
                    }
                  }),
                ),
              text('branch', '分店名'),
              text('address', '票面地址'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: text('country', '国家代码')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('$currencyPickerVersion-${r.currency}'),
                      initialValue: r.currency,
                      decoration: const InputDecoration(labelText: '币种'),
                      items: currencies.keys
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (value) async {
                        try {
                          await syncFields();
                          final revised = await editReceipt('currency', {
                            'currency': value!,
                          });
                          if (!context.mounted) return;
                          if ((r.lines.isNotEmpty || r.totalMinor != null) &&
                              !await confirm(
                                context,
                                '修正票面币种？',
                                '金额数字保持不变，仅修正币种标记，不进行汇率换算。',
                              )) {
                            if (mounted) {
                              setState(() {
                                currencyPickerVersion++;
                              });
                            }
                            return;
                          }
                          if (!mounted) return;
                          setState(() {
                            currencyPickerVersion++;
                            draft = revised;
                            populate();
                          });
                          changed();
                        } catch (e) {
                          if (context.mounted) {
                            showError(context, e);
                            setState(() {
                              currencyPickerVersion++;
                            });
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
              Card(
                elevation: 0,
                color: r.timeSource.startsWith('estimated')
                    ? warning
                    : Colors.white,
                child: ListTile(
                  title: Text(dateText(r.occurredAt, widget.zone)),
                  subtitle: Text(
                    '${widget.zone}${r.timeSource.startsWith('estimated') ? ' · 时间含估计值' : ''}',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: changeTime,
                ),
              ),
              const SizedBox(height: 12),
              text('total', '收据总额'),
              TextButton(
                onPressed: () => act(() async {
                  final result = await editReceipt('total_from_lines', {});
                  if (!mounted) return;
                  setState(() {
                    draft = result;
                    populate();
                  });
                  changed();
                }),
                child: const Text('明确使用明细合计作为总额'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  '商品与调整',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                trailing: IconButton(
                  tooltip: '添加明细',
                  onPressed: () => editLine(null),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
              if (selected.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => act(split),
                      child: const Text('拆分所选行'),
                    ),
                    TextButton(
                      onPressed: () => act(merge),
                      child: const Text('合并所选行'),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(selected.clear);
                      },
                      child: const Text('取消选择'),
                    ),
                  ],
                ),
              for (final l in r.lines)
                Card(
                  color: l.warnings.isNotEmpty ? warning : Colors.white,
                  elevation: 0,
                  child: ListTile(
                    leading: Checkbox(
                      value: selected.contains(l.id),
                      onChanged: (v) => setState(() {
                        if (v!) {
                          selected.add(l.id);
                        } else {
                          selected.remove(l.id);
                        }
                      }),
                    ),
                    title: ReceiptItemName(
                      productName:
                          l.productNameEdit ?? l.display['productName'],
                      printedName: l.rawName,
                      kind: l.kind,
                    ),
                    subtitle: Text(
                      '${kindLabels[l.kind]}${(l.taxCode ?? '').isEmpty ? '' : ' · 税码 ${l.taxCode}'}${(l.sku ?? '').isEmpty ? '' : ' · SKU ${l.sku}'}',
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          l.amountMinor == null
                              ? '缺少金额'
                              : money(l.amountMinor, r.currency),
                        ),
                        InkWell(
                          onTap: () => removeLine(l),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 18),
                          ),
                        ),
                      ],
                    ),
                    onTap: () => editLine(l),
                  ),
                ),
              if (r.lines.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('还没有明细，可手工添加。'),
                ),
              if (r.totalMinor != null)
                Notice(
                  '已录入明细 ${money(r.knownTotal, r.currency)}\n待核对差额 ${money(r.difference, r.currency)}',
                ),
              Text(
                '追溯编号：${r.id}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
        ),
        bottomSheet: Container(
          color: paper,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                if (!r.posted)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              await persistDraft();
                              if (error == null && context.mounted) {
                                Navigator.pop(context);
                              }
                            }),
                      child: const Text('保存草稿'),
                    ),
                  ),
                if (!r.posted) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : save,
                    child: Text(busy ? '处理中…' : '确认并保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EvidencePainter extends CustomPainter {
  final Map<String, dynamic> box;
  EvidencePainter(this.box);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      box['x0'] * size.width,
      box['y0'] * size.height,
      box['x1'] * size.width,
      box['y1'] * size.height,
    );
    canvas.drawRect(rect, Paint()..color = const Color(0x55FFD54F));
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFFFFA000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant EvidencePainter old) => old.box != box;
}
