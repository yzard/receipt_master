import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:image_picker/image_picker.dart';

import '../data/store.dart';
import '../domain/models.dart';
import 'common.dart';
import 'editor.dart';
import 'catalog.dart';
import 'reports.dart';
import 'settings.dart';
import 'receipt_row.dart';
import 'capture.dart';

class HomePage extends StatefulWidget {
  final AppStore store;
  final String zone;
  const HomePage({super.key, required this.store, required this.zone});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int page = 0;
  late String zone;
  List<Map<String, dynamic>>? receipts;
  Object? error;
  bool importing = false;
  Timer? polling;
  String sortBy = "created_at";
  String direction = "desc";
  bool refreshing = false;
  bool refreshAgain = false;
  @override
  void initState() {
    super.initState();
    zone = widget.zone;
    WidgetsBinding.instance.addObserver(this);
    refresh();
    widget.store.addListener(submissionChanged);
    recoverPicker();
    widget.store.retryUploads().catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  @override
  void dispose() {
    polling?.cancel();
    widget.store.removeListener(submissionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshZone();
      widget.store.retryUploads().catchError((Object e) {
        if (mounted) showError(context, e);
      });
      refresh();
    }
  }

  Future<void> refreshZone() async {
    try {
      final name = (await FlutterTimezone.getLocalTimezone()).identifier;
      if (mounted) setState(() => zone = name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> recoverPicker() async {
    if (!Platform.isAndroid) return;
    try {
      final lost = await ImagePicker().retrieveLostData();
      if (lost.files?.isNotEmpty ?? false) {
        final marker = File('${widget.store.cacheRoot}/pending_capture');
        final target = await marker.exists()
            ? await marker.readAsString()
            : null;
        final photos = <Uint8List>[];
        for (final file in lost.files!) {
          photos.add(await file.readAsBytes());
        }
        await widget.store.queueCapture(
          photos,
          true,
          DateTime.now().millisecondsSinceEpoch,
          zone,
          receiptId: target,
        );
        if (await marker.exists()) await marker.delete();
        if (mounted) showError(context, const InputError('已恢复照片，正在后台上传'));
      } else if (lost.exception != null) {
        throw const InputError('未能恢复拍摄，请重新打开草稿补拍');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void updatePolling() {
    final active =
        widget.store.submissionStates.isNotEmpty ||
        (receipts?.any(
              (r) => ['queued', 'running'].contains(r['recognition_status']),
            ) ??
            false);
    if (active) {
      polling ??= Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    } else {
      polling?.cancel();
      polling = null;
    }
  }

  void submissionChanged() {
    updatePolling();
    if (mounted) {
      setState(() {});
      refresh();
    }
  }

  Future<void> refresh() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    try {
      final requestedSort = sortBy, requestedDirection = direction;
      final result = await widget.store.receipts(
        false,
        productNameId: null,
        sortBy: requestedSort,
        direction: requestedDirection,
      );
      if (mounted &&
          requestedSort == sortBy &&
          requestedDirection == direction) {
        setState(() {
          receipts = result;
          error = null;
          updatePolling();
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      refreshing = false;
      if (mounted && refreshAgain) {
        refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> open(String? id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            EditorPage(store: widget.store, zone: zone, receiptId: id),
      ),
    );
    refresh();
  }

  Future<void> capture(bool camera) async {
    if (importing) return;
    setState(() => importing = true);
    try {
      if (camera) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => CapturePage(
              cacheRoot: widget.store.cacheRoot,
              onComplete: (photos) async {
                await widget.store.queueCapture(
                  photos,
                  true,
                  DateTime.now().millisecondsSinceEpoch,
                  zone,
                );
              },
            ),
          ),
        );
        return;
      }
      final marker = File('${widget.store.cacheRoot}/pending_capture');
      if (await marker.exists()) await marker.delete();
      final files = await ImagePicker().pickMultiImage();
      final selected = files.whereType<XFile>().toList();
      if (selected.isEmpty) return;
      final photos = <Uint8List>[];
      for (final file in selected) {
        photos.add(await file.readAsBytes());
      }
      await widget.store.queueCapture(
        photos,
        camera,
        DateTime.now().millisecondsSinceEpoch,
        zone,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => importing = false);
        await refresh();
      }
    }
  }

  String jobLabel(dynamic status) => switch (status) {
    'queued' => '排队中 · ',
    'running' => '识别中 · ',
    'failed' => '',
    'applied' => '',
    'succeeded' => '结果待处理 · ',
    _ => '',
  };

  Future<void> deleteReceipt(String id) async {
    try {
      await widget.store.purge(id);
      await refresh();
    } catch (e) {
      if (mounted) showError(context, e);
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (page) {
      0 => receiptList(),
      1 => ReportsPage(
        key: ValueKey('reports-$zone'),
        store: widget.store,
        zone: zone,
        onReceipt: (id) => open(id),
      ),
      2 => CatalogPage(
        store: widget.store,
        zone: zone,
        onReceipt: (id) => open(id),
      ),
      _ => SettingsPage(store: widget.store, zone: zone, onChanged: refresh),
    };
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Receipt Master',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -.6),
            ),
            Text(
              [
                '收据 · 留下每笔消费',
                '报表 · 看清每类支出',
                '商品管理 · 管理商品与商店',
                '设置 · 数据由你掌握',
              ][page],
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: page == 0
            ? [
                IconButton(
                  tooltip: '刷新',
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (importing && page == 0) const LinearProgressIndicator(),
            if (widget.store.submissionStates.isNotEmpty)
              ListTile(
                dense: true,
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('后台提交 ${widget.store.submissionStates.length} 张收据'),
                subtitle: Text(
                  widget.store.submissionStates.values.any(
                        (v) => v.startsWith('上传失败'),
                      )
                      ? '部分上传失败，点击重试；照片已保留'
                      : '上传中，可以继续拍照或查看其他页面',
                ),
                onTap: () => widget.store.retrySubmissions(),
              ),
            Expanded(child: content),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: page == 0
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: importing ? null : () => capture(true),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('拍照'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: importing ? null : () => capture(false),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('上传照片'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: importing ? null : () => open(null),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('手动'),
                ),
              ],
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (value) {
          setState(() => page = value);
          if (value == 0) refresh();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: '收据',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            label: '报表',
          ),
          NavigationDestination(
            icon: Icon(Icons.category_outlined),
            label: '商品管理',
          ),
          NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
        ],
      ),
    );
  }

  Widget receiptList() {
    if (error != null) {
      return Center(
        child: TextButton(onPressed: refresh, child: const Text('数据加载失败，点击重试')),
      );
    }
    if (receipts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (receipts!.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: '从第一张收据开始',
        detail: '拍摄、导入照片或手工录入。\n确认每一笔，慢慢看清日常消费。',
      );
    }
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        itemCount: receipts!.length + 1,
        separatorBuilder: (_, i) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == 0) {
            return ReceiptTableHeader(
              sortBy: sortBy,
              direction: direction,
              onSort: (key) {
                setState(() {
                  direction = key == sortBy
                      ? (direction == 'asc' ? 'desc' : 'asc')
                      : (key == 'store' ? 'asc' : 'desc');
                  sortBy = key;
                });
                refresh();
              },
            );
          }
          final r = receipts![i - 1];
          return ReceiptRow(
            key: ValueKey(r['receipt_id']),
            name:
                '${r['status'] == 'posted' ? '' : jobLabel(r['recognition_status'])}${(r['raw_store'] as String?)?.isNotEmpty == true ? r['raw_store'] : '未填写商店'}',
            date: dateText(r['created_at_utc_ms'], zone),
            receiptDate: dateText(r['occurred_at_utc_ms'], zone),
            failed: r['recognition_status'] == 'failed',
            draft: r['status'] == 'draft',
            amount: r['total_minor'] == null
                ? '待填写'
                : money(r['total_minor'], r['currency_code']),
            onOpen: () => open(r['receipt_id']),
            onDelete: () => deleteReceipt(r['receipt_id']),
          );
        },
      ),
    );
  }
}
