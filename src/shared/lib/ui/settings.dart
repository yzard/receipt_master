import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../platform/credentials.dart';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../data/backend_connection.dart';
import '../data/backend_defaults.dart';
import '../data/android_update.dart';

import 'common.dart';

class SettingsPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Future<void> Function() onChanged;
  const SettingsPage({
    super.key,
    required this.store,
    required this.zone,
    required this.onChanged,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final endpoint = TextEditingController(), keyField = TextEditingController();
  bool busy = false, loaded = false;
  String? message;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    endpoint.dispose();
    keyField.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final connection = await loadBackendConnection();
      endpoint.text = connection.endpoint;
      keyField.text = connection.key;
      await widget.store.loadPreferences();
      if (mounted) setState(() => loaded = true);
    } catch (e) {
      if (mounted) {
        setState(() => loaded = true);
        showError(context, e);
      }
    }
  }

  Future<void> action(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
      await widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final defaults = await loadBackendDefaults();
    final connection = BackendConnection(
      endpoint.text.trim(),
      keyField.text.trim(),
      allowedHttpEndpoint: defaults.endpoint,
    );
    final origin = connection.uri.toString();
    final candidate = AppStore(
      widget.store.cacheRoot,
      client: widget.store.client,
      configuration: () async => connection,
    );
    await candidate.loadPreferences();
    const vault = credentialStore;
    await vault.write(key: 'endpoint', value: origin);
    await vault.write(key: 'api_key', value: connection.key);
    widget.store.weightUnit = candidate.weightUnit;
    widget.store.catalogVersion = candidate.catalogVersion;
    await vault.delete(key: 'model');
    if (mounted) setState(() => message = '已连接后端并通过认证。');
  }

  Future<void> checkAndroidUpdate() async {
    await action(() async {
      setState(() => message = '正在检查客户端更新…');
      final update = await AndroidUpdate.check();
      if (!mounted) return;
      if (update == null) {
        setState(() => message = '已是最新版本');
        return;
      }
      if (!await confirm(
        context,
        '发现客户端更新',
        '版本 ${update.release.versionName}（${update.release.versionCode}），约 ${(update.release.bytes / 1048576).toStringAsFixed(1)} MB。现在下载并安装？',
      )) {
        return;
      }
      final result = await update.downloadAndInstall((progress) {
        if (mounted) {
          setState(() => message = '正在下载更新 ${(progress * 100).toInt()}%');
        }
      });
      if (mounted) {
        setState(
          () => message = result == 'permission_required'
              ? '请允许此应用安装更新，返回后再次点击“检查客户端更新”继续安装。'
              : '已打开系统安装器，请确认安装。',
        );
      }
    });
  }

  Future<void> exportFile(String name, Uint8List bytes, String mime) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final temp = await getTemporaryDirectory();
      final file = File(p.join(temp.path, name));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime)],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      await File(location.path).writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> backupData() async {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final bytes = await widget.store.createBackup(stamp);
    await exportFile('receipts-$stamp.receiptbackup', bytes, 'application/zip');
    if (mounted) setState(() => message = '备份已生成。请在系统面板中保存到你选择的位置。');
  }

  Future<void> restoreData() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    if (!await confirm(
      context,
      '整体恢复备份',
      '当前收据、商品和照片会被备份替换，不合并。替换前会在后端保留一份恢复点。此操作影响连接同一后端的所有设备。',
    )) {
      return;
    }
    final bytes = await file.readAsBytes();
    final result = await widget.store.restoreBackup(bytes);
    await load();
    if (mounted) setState(() => message = result);
  }

  Future<void> exportRecovery() async {
    final bytes = await widget.store.latestBackup();
    await exportFile('server-recovery.receiptbackup', bytes, 'application/zip');
  }

  Future<void> csv() async {
    final zone = widget.zone;
    final text = await widget.store.csvExport(zone);
    await exportFile(
      'receipt-items.csv',
      Uint8List.fromList(utf8.encode(text)),
      'text/csv',
    );
  }

  Future<void> trash() async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TrashPage(store: widget.store, zone: widget.zone),
      ),
    );
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    return AbsorbPointer(
      absorbing: busy,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null) Notice(message!),
          if (Platform.isAndroid) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : checkAndroidUpdate,
              icon: const Icon(Icons.system_update),
              label: const Text('检查客户端更新'),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => action(widget.store.retryUploads),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('重试未完成的照片上传'),
          ),
          DropdownButtonFormField<String>(
            initialValue: widget.store.weightUnit,
            decoration: const InputDecoration(
              labelText: '全局重量显示单位',
              helperText: '收据与商品统一显示此单位；数据库统一保存克数。',
            ),
            items: const ['g', 'kg', 'lb', 'oz']
                .map((unit) => DropdownMenuItem(value: unit, child: Text(unit)))
                .toList(),
            onChanged: busy
                ? null
                : (unit) {
                    if (unit != null) {
                      action(() async {
                        await widget.store.saveWeightUnit(unit);
                      });
                    }
                  },
          ),
          const SizedBox(height: 24),
          const Text(
            '后端连接',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('所有收据和照片由下方后端保存，两台设备连接同一后端即可共享数据。'),
          const SizedBox(height: 16),
          TextField(
            controller: endpoint,
            decoration: const InputDecoration(labelText: '后端 API 地址'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: keyField,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '后端访问密钥'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => action(save),
            child: const Text('连接并验证'),
          ),
          const SizedBox(height: 24),
          const Text(
            '后端数据',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('导出完整备份'),
            subtitle: const Text('包含照片、草稿和回收站；不含密钥'),
            onTap: () => action(backupData),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('从备份整体恢复'),
            onTap: () => action(restoreData),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('导出最近一次后端备份'),
            onTap: () => action(exportRecovery),
          ),
          ListTile(
            leading: const Icon(Icons.table_view_outlined),
            title: const Text('导出明细 CSV'),
            onTap: () => action(csv),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('回收站'),
            onTap: trash,
          ),
          const SizedBox(height: 24),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class TrashPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  const TrashPage({super.key, required this.store, required this.zone});
  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<Map<String, dynamic>> rows = [];
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.store.receipts(
        true,
        productNameId: null,
        sortBy: "created_at",
        direction: "desc",
      );
      if (mounted) {
        setState(() {
          rows = result;
          loaded = true;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('回收站')),
    body: !loaded
        ? const Center(child: CircularProgressIndicator())
        : rows.isEmpty
        ? const EmptyState(
            icon: Icons.delete_outline,
            title: '回收站是空的',
            detail: '删除的收据可在这里恢复。',
          )
        : ListView(
            children: [
              for (final r in rows)
                ListTile(
                  title: Text(r['raw_store'] ?? '未命名收据'),
                  subtitle: Text(
                    dateText(r['occurred_at_utc_ms'], widget.zone),
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '恢复',
                        icon: const Icon(Icons.restore),
                        onPressed: () async {
                          try {
                            final id = r['receipt_id'] as String;
                            await widget.store.trash(id, null);
                            await load();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '永久删除',
                        icon: const Icon(Icons.delete_forever),
                        onPressed: () async {
                          try {
                            if (!await confirm(
                              context,
                              '永久删除？',
                              '此操作不能从回收站恢复。',
                            )) {
                              return;
                            }
                            final id = r['receipt_id'] as String;
                            await widget.store.purge(id);
                            await load();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
  );
}
