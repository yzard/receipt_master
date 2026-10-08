import '../l10n/strings.dart';

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
import 'logo_aliases.dart';
import 'reports.dart';
import 'settings.dart';
import 'receipt_row.dart';
import 'capture.dart';
import 'app_theme.dart';

class HomePage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Appearance appearance;
  const HomePage({
    super.key,
    required this.store,
    required this.zone,
    required this.appearance,
  });
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();
  int page = 0;
  final Set<int> visitedPages = {0};
  final scrollControllers = List.generate(5, (_) => ScrollController());
  late String zone;
  List<Map<String, dynamic>>? receipts;
  Object? error;
  bool displayingCache = false;
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
    restoreReceiptCache();
    refresh();
    widget.store.addListener(submissionChanged);
    widget.store.receiptUpdates.addListener(receiptUpdated);
    recoverPicker();
    widget.store.retryUploads().catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  Future<void> restoreReceiptCache() async {
    final requestedSort = sortBy, requestedDirection = direction;
    final cached = await widget.store.cachedReceipts(
      sortBy: requestedSort,
      direction: requestedDirection,
    );
    if (mounted &&
        receipts == null &&
        cached != null &&
        requestedSort == sortBy &&
        requestedDirection == direction) {
      setState(() {
        receipts = cached;
        displayingCache = true;
      });
    }
  }

  @override
  void dispose() {
    for (final controller in scrollControllers) {
      controller.dispose();
    }
    polling?.cancel();
    widget.store.removeListener(submissionChanged);
    widget.store.receiptUpdates.removeListener(receiptUpdated);
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
        widget.store.offlineMessage != null ||
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

  void receiptUpdated() {
    final update = widget.store.receiptUpdates.value;
    if (!mounted || update == null) return;
    setState(() {
      receipts = applyReceiptUpdate(receipts ?? [], update);
      updatePolling();
    });
  }

  Future<void> refresh() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    try {
      final requestedSort = sortBy, requestedDirection = direction;
      final reconnecting = widget.store.offlineMessage != null;
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
          displayingCache = false;
          error = null;
          updatePolling();
        });
        if (reconnecting && widget.store.offlineMessage == null) {
          unawaited(
            widget.store.retryUploads().catchError((Object e) {
              if (mounted) showError(context, e);
            }),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          updatePolling();
        });
      }
    } finally {
      refreshing = false;
      if (mounted && refreshAgain) {
        refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> open(String? id) async {
    await openPageOverlay<void>(
      context,
      EditorPage(store: widget.store, zone: zone, receiptId: id),
    );
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
    'queued' => context.tr("排队中 · "),
    'running' => context.tr("识别中 · "),
    'failed' => '',
    'applied' => '',
    'succeeded' => context.tr("结果待处理 · "),
    _ => '',
  };

  Future<void> deleteReceipt(String id) async {
    if (!await confirm(
      context,
      context.tr("永久删除这张收据？"),
      context.tr("收据、照片和识别记录会从服务器删除，无法恢复。"),
    )) {
      return;
    }
    try {
      await widget.store.purge(id);
    } catch (e) {
      if (mounted) showError(context, e);
      await refresh();
    }
  }

  void openMenu() => scaffoldKey.currentState?.openDrawer();

  void choosePage(int destination) {
    scaffoldKey.currentState?.closeDrawer();
    setState(() {
      visitedPages.add(destination);
      page = destination;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    Widget content(int index) => switch (index) {
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
      3 => LogoAliasesPage(
        store: widget.store,
        receiptId: null,
        suggestedName: '',
        embedded: true,
      ),
      _ => SettingsPage(
        store: widget.store,
        zone: zone,
        onChanged: refresh,
        appearance: widget.appearance,
      ),
    };
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: Colors.transparent,
      drawer: NavigationDrawer(
        selectedIndex: page,
        onDestinationSelected: choosePage,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(28, 48, 20, 24),
            child: Text(
              'Receipt Master',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: Text(context.tr("收据")),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: Text(context.tr("报表")),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.category_outlined),
            selectedIcon: Icon(Icons.category),
            label: Text(context.tr("商品")),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: Text(context.tr("店铺")),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: Text(context.tr("设置")),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.surface,
                    scheme.primaryContainer.withValues(alpha: .24),
                    scheme.surface,
                  ],
                  stops: const [0, .48, 1],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(top: topInset),
              child: Column(
                children: [
                  if (importing && page == 0) const LinearProgressIndicator(),
                  if (widget.store.submissionStates.isNotEmpty)
                    Material(
                      color: scheme.primaryContainer.withValues(alpha: .65),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.cloud_upload_outlined),
                        title: Text(
                          context.tr("后台提交 {0} 张收据", [
                            widget.store.submissionStates.length,
                          ]),
                        ),
                        subtitle: Text(
                          widget.store.submissionStates.values.any(
                                (v) => v.startsWith('上传失败'),
                              )
                              ? context.tr("部分上传失败，点击重试；照片已保留")
                              : context.tr("上传中，可以继续使用其他页面"),
                        ),
                        onTap: () => widget.store.retrySubmissions(),
                      ),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: page,
                      children: [
                        for (var index = 0; index < 5; index++)
                          visitedPages.contains(index)
                              ? KeyedSubtree(
                                  key: ValueKey('workspace-page-$index'),
                                  child: TickerMode(
                                    enabled: page == index,
                                    child: PrimaryScrollController(
                                      controller: scrollControllers[index],
                                      child: content(index),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: bottomInset + 14,
            child: Row(
              children: [
                FrostedBar(
                  radius: BorderRadius.circular(25),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: GestureDetector(
                      onLongPress: openMenu,
                      child: SizedBox(
                        width: 58,
                        height: 58,
                        child: IconButton(
                          tooltip: context.tr("打开导航菜单"),
                          onPressed: openMenu,
                          icon: const Icon(Icons.menu_rounded, size: 28),
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (page == 0)
                  FrostedBar(
                    radius: BorderRadius.circular(25),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 58,
                            child: _QuickAction(
                              label: context.tr("拍照"),
                              icon: Icons.camera_alt_outlined,
                              primary: true,
                              onTap: importing ? null : () => capture(true),
                            ),
                          ),
                          SizedBox(
                            width: 58,
                            child: _QuickAction(
                              label: context.tr("上传照片"),
                              icon: Icons.photo_library_outlined,
                              onTap: importing ? null : () => capture(false),
                            ),
                          ),
                          SizedBox(
                            width: 58,
                            child: _QuickAction(
                              label: context.tr("手动"),
                              icon: Icons.edit_note_outlined,
                              onTap: importing ? null : () => open(null),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget receiptList() {
    final rows = receipts ?? [];
    final status = error != null
        ? context.translatedMessage(error.toString())
        : widget.store.offlineMessage != null
        ? context.tr(widget.store.offlineMessage!)
        : displayingCache
        ? context.tr('显示缓存，正在连接')
        : null;
    final subtitle = receipts == null
        ? status ?? context.tr('正在加载…')
        : [
            context.tr('共 {0} 张收据', [rows.length]),
            ?status,
          ].join('\n');
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        key: const PageStorageKey("receipt-overview"),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        itemCount: receipts == null || rows.isEmpty ? 2 : rows.length + 2,
        separatorBuilder: (_, i) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == 0) {
            return PageHeading(
              title: context.tr("收据"),
              subtitle: subtitle,
              trailing: IconButton(
                tooltip: context.tr("刷新收据"),
                onPressed: refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            );
          }
          if (i == 1 && error != null && rows.isEmpty) {
            return Column(
              children: [
                Text(context.tr("数据加载失败")),
                const SizedBox(height: 8),
                SelectableText(
                  context.translatedMessage(error.toString()),
                  textAlign: TextAlign.center,
                ),
                TextButton(onPressed: refresh, child: Text(context.tr("点击重试"))),
              ],
            );
          }
          if (i == 1 && receipts == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (i == 1 && rows.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_long_outlined,
              title: context.tr("从第一张收据开始"),
              detail: context.tr("拍摄、导入照片或手工录入。\n确认每一笔，慢慢看清日常消费。"),
            );
          }
          if (i == 1) {
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
          final r = rows[i - 2];
          return ReceiptRow(
            key: ValueKey(r['receipt_id']),
            name:
                '${r['status'] == 'posted' ? '' : jobLabel(r['recognition_status'])}${(r['raw_store'] as String?)?.isNotEmpty == true ? r['raw_store'] : context.tr("未填写店铺")}',
            date: dateText(r['created_at_utc_ms'], zone),
            receiptDate: dateText(r['occurred_at_utc_ms'], zone),
            failed: r['recognition_status'] == 'failed',
            draft: r['status'] == 'draft',
            amount: r['total_minor'] == null
                ? context.tr("待填写")
                : money(r['total_minor'], r['currency_code']),
            onOpen: () => open(r['receipt_id']),
            onDelete: () => deleteReceipt(r['receipt_id']),
          );
        },
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: primary ? scheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(19),
      child: SizedBox(
        height: 58,
        child: IconButton(
          tooltip: label,
          onPressed: onTap,
          icon: Icon(
            icon,
            size: 25,
            color: primary ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
